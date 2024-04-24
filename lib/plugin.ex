defmodule PluginCrashInfo do
  use TypeCheck
  use TypeCheck.Defstruct

  defstruct!(
    plugin: _ :: module(),
    type: _ :: :throw | :error,
    error: _ :: Exception.t(),
    stacktrace: _ :: Exception.stacktrace()
  )

  defmacro new(kwlist) do
    quote do
      struct!(
        unquote(__MODULE__),
        unquote(kwlist)
      )
    end
  end
end

defmodule Plugin do
  use TypeCheck
  require Logger
  require PluginCrashInfo
  alias PluginCrashInfo, as: CrashInfo
  alias Stampede, as: S
  alias S.{Msg, Response, InteractionForm}
  require InteractionForm
  @first_response_timeout 500

  @callback process_msg(SiteConfig.t(), Msg.t()) :: nil | Response.t()

  # TODO: replace with predicate? and handle prefix cleaning seperately
  @doc "Given a config and message, indicate if we should respond, and if so what is the relevant part of the message?"
  @callback at_module?(SiteConfig.t(), Msg.t()) :: boolean() | {:cleaned, text :: String.t()}

  @typedoc """
  Describe uses for a plugin in a input-output manner, no prefix included.
  - {"help sentience", "(prints the help for the Sentience plugin)"}
  - "Usage example not fitting the tuple format"
  """
  @type! usage_tuples :: list(TxtBlock.t() | {TxtBlock.t(), TxtBlock.t()})

  @callback usage() :: usage_tuples()
  @callback description() :: TxtBlock.t()

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl Plugin
      def at_module?(cfg, msg) do
        # Should we process the message?
        if msg.at_bot? or msg.dm? or msg.prefix do
          {:cleaned, msg.body}
        else
          false
        end
      end

      defoverridable at_module?: 2
    end
  end

  @doc "returns loaded modules using the Plugin behavior."
  @spec! ls() :: MapSet.t(module())
  def ls() do
    S.find_submodules(Plugin)
    |> Enum.reduce(MapSet.new(), fn
      mod, acc ->
        b =
          mod.__info__(:attributes)
          |> Keyword.get(:behaviour, [])

        if Plugin in b do
          MapSet.put(acc, mod)
        else
          acc
        end
    end)
  end

  @spec! ls(:all | :none | MapSet.t()) :: MapSet.t()
  def ls(:none), do: MapSet.new()
  def ls(:all), do: ls()

  def ls(enabled) do
    MapSet.intersection(enabled, ls())
  end

  def default_plugin_mfa(plug, [cfg, msg]) do
    {plug, :process_msg, [cfg, msg]}
  end

  @type! job_result ::
           {:job_error, :timeout}
           | {:job_error, tuple()}
           | {:job_ok, nil}
           | {:job_ok, %Response{}}
  @type! plugin_job_result :: {atom(), job_result()}

  @doc "Attempt some task, safely catch errors, and format the error report for the originating service"
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
        st = __STACKTRACE__

        error_info =
          CrashInfo.new(plugin: m, type: t, error: e, stacktrace: st)

        {:ok, formatted} =
          Service.apply_service_function(
            cfg,
            :log_plugin_error,
            [cfg, msg, error_info]
          )

        Logger.error(
          fn ->
            formatted
            |> TxtBlock.to_binary(:logger)
          end,
          crash_reason: {e, st},
          stampede_component: SiteConfig.fetch!(cfg, :service),
          stampede_msg_id: msg.id,
          stampede_plugin: m,
          stampede_already_logged: true
        )

        {:job_error, {e, st}}
    end
  end

  @spec! query_plugins(list(S.module_function_args() | module()), SiteConfig.t(), S.Msg.t()) ::
           nil | {response :: Response.t(), interaction_id :: S.interaction_id()}
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
             [this_plug, cfg, msg]
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

    %{r: chosen_response, tb: traceback} = resolve_responses(task_results)

    case chosen_response do
      nil ->
        nil

      %Response{callback: nil} ->
        {:ok, iid} =
          S.InteractionForm.new(
            service: cfg.service,
            plugin: chosen_response.origin_plug,
            msg: msg,
            response: chosen_response,
            channel_lock: chosen_response.channel_lock,
            traceback: traceback
          )
          |> S.Interact.prepare_interaction!()

        {chosen_response, iid}

      %Response{callback: {mod, fun, args}} ->
        followup =
          apply(mod, fun, [cfg | args])

        new_tb = [
          traceback,
          "\nTop response was a callback, so i called it. It responded with: \n\"",
          followup.text,
          "\"",
          followup.why
        ]

        {:ok, iid} =
          S.InteractionForm.new(
            service: cfg.service,
            plugin: chosen_response.origin_plug,
            msg: msg,
            response: followup,
            channel_lock: followup.channel_lock,
            traceback: new_tb
          )
          |> S.Interact.prepare_interaction!()

        {followup, iid}
    end
  end

  @doc "Poll all enabled plugins and choose the most relevant one."
  @spec! get_top_response(SiteConfig.t(), Msg.t()) ::
           nil | {response :: Response.t(), interaction_id :: S.interaction_id()}
  def get_top_response(cfg, msg) do
    case S.Interact.channel_locked?(msg.channel_id) do
      {{m, f, a}, _plugin, _iid} ->
        {response, iid} = query_plugins([{m, f, [cfg, msg | a]}], cfg, msg)

        explained_response =
          Map.update!(response, :why, fn tb ->
            [
              "Channel ",
              msg.channel_id |> inspect(),
              "was locked to module ",
              m |> inspect(),
              ", function ",
              "f",
              ", so we called it.\n"
              | tb
            ]
          end)

        {explained_response, iid}

      false ->
        __MODULE__.ls(SiteConfig.fetch!(cfg, :plugs))
        |> MapSet.to_list()
        |> query_plugins(cfg, msg)
    end
  end

  @doc "Organize plugin results by confidence"
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

  @doc "Choose best response, creating a traceback along the way."
  @spec! resolve_responses(nonempty_list(plugin_job_result())) :: %{
           # NOTE: reversing order from 'nil | response' to 'response | nil' makes Dialyzer not count nil?
           r: nil | S.Response.t(),
           tb: S.traceback()
         }
  def resolve_responses(tlist) do
    task_sort(tlist)
    |> do_rr(nil, [])
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
      traceback,
      "\nWe asked ",
      plug |> inspect(),
      ", and it decided not to answer."
    ])
  end

  def do_rr(
        [{plug, {:job_error, :timeout}} | rest],
        chosen_response,
        traceback
      ) do
    do_rr(rest, chosen_response, [
      traceback,
      "\nWe asked ",
      plug |> inspect(),
      ", but it timed out."
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
          traceback,
          "\nWe asked ",
          plug |> inspect(),
          ", and it responded with confidence ",
          response.confidence |> inspect(),
          " offering a callback.\nWhen asked why, it said: \"",
          response.why,
          "\""
        ]
      else
        [
          traceback,
          "\nWe asked ",
          plug |> inspect(),
          ", and it responded with confidence ",
          response.confidence |> inspect(),
          ":\n",
          {:quote_block, response.text},
          "When asked why, it said: \"",
          response.why,
          "\""
        ]
      end

    if chosen_response == nil do
      do_rr(rest, response, [
        tb,
        "\nWe chose this response."
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
        traceback,
        "\nWe asked ",
        plug |> inspect(),
        ", but there was an error of type ",
        val |> inspect(),
        "."
      ]
    )
  end
end
