defmodule Plugin do
  use TypeCheck
  require Logger
  alias Stampede, as: S
  alias S.{Msg, Response, Interaction}
  require Interaction
  @first_response_timeout 500
  @callback process_msg(SiteConfig.t(), Msg.t()) :: nil | Response.t()

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour unquote(__MODULE__)
    end
  end

  def ls() do
    S.find_submodules(__MODULE__)
  end

  def default_plugin_mfa(plug, args = [cfg, msg]) do
    {plug, :process_msg, args}
  end

  @spec! ls(:all | :none | MapSet.t()) :: MapSet.t()
  def ls(:none), do: MapSet.new()
  def ls(:all), do: ls()

  def ls(enabled) do
    MapSet.intersection(enabled, ls())
  end

  @type! job_result ::
           {:job_error, :timeout}
           | {:job_error, tuple()}
           | {:job_ok, nil}
           | {:job_ok, %Response{}}
  @type! plugin_job_result :: {atom(), job_result()}

  @spec! get_response(S.module_function_args() | atom(), SiteConfig.t(), S.Msg.t()) ::
           job_result()
  def get_response(plugin, cfg, msg) when is_atom(plugin),
    do: get_response(default_plugin_mfa(plugin, [cfg, msg]), cfg, msg)

  def get_response({m, f, a}, cfg, msg) do
    # if an error occurs in process_msg, catch it and return as data
    try do
      {
        :job_ok,
        apply(m, f, a)
      }
    catch
      t, e ->
        error_type =
          case t do
            :error ->
              "an error"

            :throw ->
              "a throw"
          end

        st = __STACKTRACE__
        Logger.info("Caught #{error_type} in plugin #{m}:\n#{Exception.format(:error, e, st)}")

        log = """
        Message from #{inspect(msg.author_id)} lead to #{error_type}, description #{inspect(e)}.
        Stacktrace:
        #{Exception.format_stacktrace(st)}
        """

        {:job_error,
         {e.__struct__, spawn(SiteConfig.fetch!(cfg, :service), :log_plugin_error, [cfg, log])}}
    end
  end

  def query_plugins(call_list, cfg, msg) do
    tasks =
      Enum.map(call_list, fn
        mfa = {this_plug, _func, _args} ->
          {this_plug,
           Task.Supervisor.async_nolink(
             S.quick_task_via(),
             __MODULE__,
             :get_response,
             [mfa, cfg, msg]
           )}

        this_plug when is_atom(this_plug) ->
          {this_plug,
           Task.Supervisor.async_nolink(
             S.quick_task_via(),
             __MODULE__,
             :get_response,
             [default_plugin_mfa(this_plug, [cfg, msg]), cfg, msg]
           )}
      end)

    # make a map of task references to the plugins they were called for
    task_ids =
      Enum.reduce(tasks, %{}, fn
        {plug, %{ref: ref}}, acc ->
          Map.put(acc, ref, plug)
      end)

    # to yield with Task.yield_many(), the plugins and tasks must part
    task_results =
      Enum.map(tasks, &Kernel.elem(&1, 1))
      |> Task.yield_many(timeout: @first_response_timeout)
      |> Enum.map(fn {task, result} ->
        # they are reunited :-)
        {
          task_ids[task.ref],
          result || Task.shutdown(task, :brutal_kill)
        }
      end)
      |> Enum.map(fn {task, result} ->
        # they are reunited :-)
        {
          task,
          case result do
            {:ok, job_result} ->
              job_result

            nil ->
              {:job_error, :timeout}

            other ->
              raise "task unexpected return, reason #{inspect(other, pretty: true)}"
              result
          end
        }
      end)
      |> Enum.map(fn
        {plug, result} ->
          case result do
            r = {:job_ok, return} ->
              if is_struct(return, S.Response) and plug != return.origin_plug do
                raise(
                  "Plug #{plug} doesn't match #{return.origin_plug}. I screwed up the task running code."
                )
              end

              {plug, r}

            {:job_error, reason} ->
              {plug, {:job_error, reason}}
          end
      end)
      |> task_sort()

    %{r: chosen_response, tb: traceback} = resolve_responses(task_results)

    case chosen_response do
      nil ->
        nil

      chosen_response = %Response{callback: nil} ->
        S.Interaction.new(
          plugin: chosen_response.origin_plug,
          msg: msg,
          response: chosen_response,
          channel_lock: chosen_response.channel_lock,
          traceback: traceback
        )
        |> S.Interact.record_interaction!()

        # TODO: logging interactions
        chosen_response

      %Response{callback: {mod, fun, args}} ->
        followup =
          apply(mod, fun, [cfg | args])

        new_tb = [
          traceback,
          "\nTop response was a callback, so i called it. It responded with: \n\"#{followup.text}\"",
          followup.why
        ]

        S.Interaction.new(
          plugin: chosen_response.origin_plug,
          msg: msg,
          response: followup,
          channel_lock: followup.channel_lock,
          traceback: new_tb
        )
        |> S.Interact.record_interaction!()

        followup
    end
  end

  @spec! get_top_response(SiteConfig.t(), Msg.t()) :: nil | Response.t()
  def get_top_response(cfg, msg) do
    case S.Interact.channel_locked?(msg.channel_id) do
      {:lock, {m, f, a}, iid} ->
        response = query_plugins([{m, f, a}], cfg, msg)

        Map.update!(response, :traceback, fn tb ->
          [
            "Channel #{msg.channel_id} was locked to module #{m}, function #{f}, so we called it.\n"
            | tb
          ]
        end)

      false ->
        __MODULE__.ls(SiteConfig.fetch!(cfg, :plugs))
        |> query_plugins(cfg, msg)
    end
  end

  @spec! task_sort(list(plugin_job_result())) :: list(plugin_job_result())
  def task_sort(tlist) do
    Enum.sort(tlist, fn
      {_plug, {:job_ok, r1}}, {_, {:job_ok, r2}} ->
        cond do
          r1 && r2 ->
            r1.confidence >= r2.confidence

          !r1 && r2 ->
            false

          r1 && !r2 ->
            true

          !r1 && !r2 ->
            true
        end

      {_plug1, {s1, _}}, {_plug2, {s2, _}} ->
        case {s1, s2} do
          {:job_ok, _} ->
            true

          {_, :job_ok} ->
            false

          _ ->
            true
        end
    end)
  end

  @spec! resolve_responses(list(plugin_job_result())) :: map()
  def resolve_responses(tlist) do
    do_rr(tlist, nil, [])
  end

  def do_rr([], chosen_response, traceback) do
    %{
      r: chosen_response,
      tb: traceback
    }
  end

  def do_rr(
        [{plug, {:job_ok, nil}} | rest],
        chosen_response,
        traceback
      ) do
    do_rr(rest, chosen_response, [
      traceback
      | "\nWe asked #{inspect(plug)}, and it decided not to answer."
    ])
  end

  def do_rr(
        [{plug, {:job_error, :timeout}} | rest],
        chosen_response,
        traceback
      ) do
    do_rr(rest, chosen_response, [
      traceback
      | "\nWe asked #{inspect(plug)}, but it timed out."
    ])
  end

  def do_rr(
        [{plug, {:job_ok, response}} | rest],
        chosen_response,
        traceback
      ) do
    tb =
      if response.callback do
        [
          traceback
          | "\nWe asked #{inspect(plug)}, and it responded with confidence #{inspect(response.confidence)} offering a callback.\nWhen asked why, it said: \"#{inspect(response.why)}\""
        ]
      else
        [
          traceback
          | """
            We asked #{inspect(plug)}, and it responded with confidence #{inspect(response.confidence)}:
            #{S.markdown_quote(response.text)}
            When asked why, it said: \"#{inspect(response.why)}\"
            """
        ]
      end

    if chosen_response == nil do
      do_rr(rest, response, [
        tb
        | "\nWe chose this response."
      ])
    else
      do_rr(rest, chosen_response, tb)
    end
  end

  def do_rr(
        [{plug, {:job_error, {val, _trace_location}}} | rest],
        chosen_response,
        traceback
      ) do
    do_rr(
      rest,
      chosen_response,
      [
        traceback
        | "\nWe asked #{inspect(plug)}, but there was an error of type #{inspect(val.__struct__)}, message #{inspect(val)}"
      ]
    )
  end
end
