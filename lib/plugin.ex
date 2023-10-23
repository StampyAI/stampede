defmodule Plugin do
  use TypeCheck
  require Logger
  alias Stampede, as: S
  alias S.{Msg, Response}
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

  @spec! ls(:all | :none | MapSet.t()) :: MapSet.t()
  def ls(:none), do: MapSet.new()
  def ls(:all), do: ls()

  def ls(enabled) do
    MapSet.intersection(enabled, ls())
  end

  @type! task_result ::
           {:error, :timeout}
           | {:ok, nil}
           | {:ok, %Response{}}
  @type! plugin_task_result :: {atom(), task_result()}

  @spec! get_top_response(SiteConfig.t(), Msg.t()) :: nil | Response.t()
  def get_top_response(cfg, msg) do
    tasks =
      __MODULE__.ls(cfg.plugs)
      |> Enum.map(fn this_plug ->
        {this_plug,
         Task.Supervisor.async_nolink(
           S.quick_task_via(cfg.app_id),
           fn ->
             # if an error occurs in process_msg, catch it and return as data
             try do
               {:ok, this_plug.process_msg(cfg, msg)}
             rescue
               e ->
                 Logger.error(Exception.format(:error, e, __STACKTRACE__))

                 {:error, e.__struct__, cfg.service.log_error(cfg, {msg, e, __STACKTRACE__})}
             end
           end
         )}
      end)

    task_ids =
      Enum.reduce(tasks, %{}, fn
        {plug, %{ref: ref}}, acc ->
          Map.put(acc, ref, plug)
      end)

    # to yield in parallel, the plugins and tasks must part
    task_results =
      Enum.map(tasks, fn {_plug, task} -> task end)
      |> Task.yield_many(timeout: @first_response_timeout)
      |> Enum.map(fn {task, result} ->
        # they are reunited :-)
        {
          task_ids[task.ref],
          result || Task.shutdown(task, :brutal_kill)
        }
      end)
      |> Enum.map(fn
        {plug, result} ->
          case result do
            {:ok, return} ->
              if is_struct(return, S.Response) and plug != return.origin_plug do
                raise(
                  "Plug #{plug} doesn't match #{return.origin_plug}. I screwed up the task running code."
                )
              end

              {plug, return}

            nil ->
              {plug, {:error, :timeout}}
          end
      end)
      |> task_sort()

    %{r: chosen_response, tb: traceback} = resolve_responses(task_results)

    case chosen_response do
      nil ->
        nil

      chosen_response = %Response{callback: nil} ->
        final_int =
          struct!(S.Interaction,
            initial_msg: msg,
            chosen_response: chosen_response,
            traceback: IO.iodata_to_binary(traceback)
          )

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

        final_int =
          struct!(S.Interaction,
            initial_msg: msg,
            chosen_response: followup,
            traceback: IO.iodata_to_binary(new_tb)
          )

        # TODO: logging interactions
        followup
    end
  end

  @spec! task_sort(list(plugin_task_result())) :: list(plugin_task_result())
  def task_sort(tlist) do
    Enum.sort(tlist, fn
      {_, {:ok, r1}}, {_, {:ok, r2}} ->
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

      {_, {s1, _}}, {_, {s2, _}} ->
        case {s1, s2} do
          {:ok, :ok} ->
            true

          {:ok, _} ->
            true

          {_, :ok} ->
            false

          _ ->
            true
        end
    end)
  end

  @spec! resolve_responses(list(plugin_task_result())) :: map()
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
        [{plug, {:ok, nil}} | rest],
        chosen_response,
        traceback
      ) do
    do_rr(rest, chosen_response, [
      traceback
      | "\nWe asked #{plug}, and it decided not to answer."
    ])
  end

  def do_rr(
        [{plug, {:error, :timeout}} | rest],
        chosen_response,
        traceback
      ) do
    do_rr(rest, chosen_response, [
      traceback
      | "\nWe asked #{plug}, but it timed out."
    ])
  end

  def do_rr(
        [{plug, {:ok, response}} | rest],
        chosen_response,
        traceback
      ) do
    tb =
      if response.callback do
        [
          traceback
          | "\nWe asked #{plug}, and it responded with confidence #{response.confidence} offering a callback.\nWhen asked why, it said: \"#{response.why}\""
        ]
      else
        [
          traceback
          | "\nWe asked #{plug}, and it responded with confidence #{response.confidence}:\n#{S.markdown_quote(response.text)}\nWhen asked why, it said: \"#{response.why}\""
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
        [{plug, {:error, val, _trace_location}} | rest],
        chosen_response,
        traceback
      ) do
    do_rr(
      rest,
      chosen_response,
      [
        traceback
        | "\nWe asked #{plug}, but there was an error of type #{val.__struct__}, message #{val.message}"
      ]
    )
  end
end
