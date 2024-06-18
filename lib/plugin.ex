defmodule PluginCrashInfo do
  @moduledoc false
  @compile [:bin_opt_info, :recv_opt_info]
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
  @moduledoc """
  Define the beavior for plugins to use.
  """
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck
  require Logger
  require PluginCrashInfo
  alias PluginCrashInfo, as: CrashInfo
  alias Stampede, as: S
  alias S.{MsgReceived, ResponseToPost, InteractionForm}
  require InteractionForm
  require Aja
  @first_response_timeout 500

  @doc """
  Decide if and how this plugin should respond
  """
  @callback respond(cfg :: SiteConfig.t(), msg :: MsgReceived.t()) :: nil | ResponseToPost.t()

  @typedoc """
  Describe uses for a plugin in a input-output manner, no prefix included.
  - {"help sentience", "(prints the help for the Sentience plugin)"}
  - "Usage example not fitting the tuple format"
  """
  @type! usage_tuples :: list(TxtBlock.t() | {TxtBlock.t(), TxtBlock.t()})

  @callback usage() :: usage_tuples()
  @callback description() :: TxtBlock.t()
  @callback description_long() :: TxtBlock.t()

  defguard is_bot_invoked(msg)
           when msg.at_bot? or msg.dm? or msg.prefix != false

  defguard is_bot_needed(cfg, msg)
           when cfg.bot_is_loud or is_bot_invoked(msg)

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour Plugin

      @impl Plugin
      def description_long(), do: description()

      defoverridable description_long: 0
    end
  end

  def valid?(mod) do
    b =
      mod.__info__(:attributes)
      |> Keyword.get(:behaviour, [])

    Plugin in b
  end

  @doc "returns loaded modules using the Plugin behavior."
  @spec! ls() :: MapSet.t(module())
  def ls() do
    S.find_submodules(Plugins)
    |> Enum.reduce(MapSet.new(), fn
      mod, acc ->
        if valid?(mod) do
          MapSet.put(acc, mod)
        else
          acc
        end
    end)
  end

  def loaded?(enabled) do
    MapSet.subset?(enabled, Plugin.ls())
  end

  def try_callback(response = %ResponseToPost{}, traceback) do
    {m, f, a} = response.callback

    followup_r =
      apply(m, f, a)

    new_tb =
      Stampede.Traceback.append(
        traceback,
        if followup_r do
          {:callback_called, followup_r.text, followup_r.why}
        else
          :callback_called_and_declined
        end
      )

    if followup_r do
      {followup_r, new_tb}
    else
      {nil, new_tb}
    end
  end

  @type! job_result ::
           {:job_error, :timeout}
           | {:job_error, tuple()}
           | {:job_ok, any()}
  @type! plugin_job_result :: {module(), job_result()}

  @doc "Attempt some task, safely catch errors, and format the error report for the originating service"
  @spec! get_response(S.module_function_args(), SiteConfig.t(), S.MsgReceived.t()) ::
           job_result()
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

  @spec! query_plugins(
           nonempty_list(module() | S.module_function_args())
           | MapSet.t(module() | S.module_function_args()),
           SiteConfig.t(),
           S.MsgReceived.t()
         ) ::
           nil | {response :: ResponseToPost.t(), interaction_id :: S.interaction_id()}
  def query_plugins(call_list, cfg, msg) do
    tasks =
      Enum.map(call_list, fn
        {this_plug, func, args} ->
          {
            this_plug,
            Task.Supervisor.async_nolink(
              S.quick_task_via(),
              __MODULE__,
              :get_response,
              [{this_plug, func, args}, cfg, msg]
            )
          }

        this_plug when is_atom(this_plug) ->
          {
            this_plug,
            Task.Supervisor.async_nolink(
              S.quick_task_via(),
              __MODULE__,
              :get_response,
              [{this_plug, :respond, [cfg, msg]}, cfg, msg]
            )
          }
      end)

    # make a map of task references to the plugins they were called for
    {
      task_id_map,
      launched_tasks,
      declined_queries
    } =
      Enum.reduce(tasks, {%{}, [], []}, fn
        {plug, t = %Task{ref: ref}}, {task_map, launched_tasks, declined_queries} ->
          {
            Map.put(task_map, ref, plug),
            [t | launched_tasks],
            declined_queries
          }

        {plug, res}, {task_map, launched_tasks, declined_queries} ->
          {
            task_map,
            launched_tasks,
            [{plug, res} | declined_queries]
          }
      end)

    # to yield with Task.yield_many(), the plugins and tasks must part
    task_results =
      launched_tasks
      |> Task.yield_many(timeout: @first_response_timeout)
      |> Enum.map(fn {task, result} ->
        # they are reunited :-)
        {
          Map.fetch!(task_id_map, task.ref),
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
              if is_struct(return, S.ResponseToPost) and plug != return.origin_plug do
                raise(
                  "Plug #{plug} doesn't match #{return.origin_plug}. I screwed up the task running code."
                )
              end

              {plug, r}

            {:job_error, reason} ->
              {plug, {:job_error, reason}}
          end
      end)

    %{r: chosen_response, tb: traceback} = resolve_responses(task_results ++ declined_queries)

    case chosen_response do
      # no plugins want to respond
      nil ->
        nil

      # we have a response to immediately provide
      %ResponseToPost{callback: nil} ->
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

      %ResponseToPost{callback: _cb} ->
        raise "Callback should have been done by now!"
    end
  end

  # def benchmark_get_top_response(cfg, msg) do
  #   ef_opts = [
  #     {:output_directory, "./eflame/"},
  #     {:output_format, :svg},
  #     :value,
  #     {:return, :value}
  #   ]

  #   :eflambe.apply({__MODULE__, :do_get_top_response, [cfg, msg]}, ef_opts)
  # end

  @doc "Poll all enabled plugins and choose the most relevant one."
  @spec! get_top_response(SiteConfig.t(), MsgReceived.t()) ::
           nil | {response :: ResponseToPost.t(), interaction_id :: S.interaction_id()}
  def get_top_response(cfg, msg = %S.MsgReceived{}) do
    case S.Interact.channel_locked?(msg.channel_id) do
      {{m, f, args_without_msg}, _plugin, _iid} ->
        {response, iid} = query_plugins([{m, f, [msg | args_without_msg]}], cfg, msg)

        explained_response =
          Map.update!(response, :why, fn why ->
            {:channel_lock_triggered, msg.channel_id, m, f, response.text, why}
            |> S.Traceback.do_single_transform()
          end)

        {explained_response, iid}

      false ->
        if is_bot_needed(cfg, msg) do
          plugs = SiteConfig.fetch!(cfg, :plugs)

          if plugs == :all do
            Plugin.ls()
          else
            plugs
          end
          |> query_plugins(cfg, msg)
        else
          nil
        end
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
           r: nil | S.ResponseToPost.t(),
           tb: S.Traceback.t()
         }
  def resolve_responses(tlist) do
    task_sort(tlist)
    |> do_rr(nil, Aja.Vector.new())
  end

  def do_rr([], possible_responses, traceback) do
    cond do
      possible_responses == nil ->
        %{r: nil, tb: traceback}

      possible_responses && Aja.vec_size(possible_responses) == 1 ->
        %{r: Aja.Vector.at!(possible_responses, 0), tb: traceback}

      true ->
        # # DEBUG
        # Aja.Vector.foldl(possible_responses, 0, fn
        #   r = %ResponseToPost{}, acc ->
        #     unless r.callback do
        #       acc == 0 || raise "This should be the first callback"
        #       acc + 1
        #     else
        #       acc == 0 || raise "There shouldn't be callbacks after a text post"
        #       acc
        #     end
        #   other, _ ->
        #     raise "Expected response, got #{other |> inspect(pretty: true)}"
        # end)

        {r, tb} =
          Aja.Vector.foldl(possible_responses, {nil, traceback}, fn
            current_r = %ResponseToPost{}, {nil, tb} ->
              # response not yet chosen
              if current_r.callback do
                try_callback(current_r, tb)
              else
                {current_r, tb}
              end

            current_r = %ResponseToPost{}, {chosen_r = %ResponseToPost{}, tb} ->
              # response already chosen
              if chosen_r.confidence < current_r.confidence do
                if current_r.callback do
                  try_callback(current_r, tb)
                else
                  {current_r, tb}
                end
              else
                {chosen_r, tb}
              end

            other, _ ->
              raise "Should never happen. #{other |> inspect(pretty: true)}"
          end)

        %{
          r: r,
          tb: tb
        }
    end
  end

  def do_rr(
        [{plug, {:job_ok, nil}} | rest],
        possible_responses,
        traceback
      ) do
    do_rr(
      rest,
      possible_responses,
      S.Traceback.append(
        traceback,
        {:declined_to_answer, plug}
      )
    )
  end

  def do_rr(
        [{plug, {:job_error, :timeout}} | rest],
        possible_responses,
        traceback
      ) do
    do_rr(
      rest,
      possible_responses,
      S.Traceback.append(
        traceback,
        {:timeout, plug}
      )
    )
  end

  def do_rr(
        [{plug, {:job_ok, response = %ResponseToPost{}}} | rest],
        possible_responses,
        traceback
      ) do
    responded_log =
      if response.callback do
        {:replied_offering_callback, plug, response.confidence, response.why}
      else
        {:replied_with_text, plug, response.confidence, response.text, response.why}
      end

    # assuming first response is highest priority response, meaning pre-sorted
    if possible_responses == nil do
      do_rr(
        rest,
        Aja.vec([response]),
        S.Traceback.append(
          traceback,
          {:response_was_chosen, responded_log}
        )
      )
    else
      # if response is a callback, we need an alternative should the callback fail.
      # Keep saving responses until one isn't a callback, so we aren't left empty handed.
      non_callback_available =
        Aja.Vector.at!(possible_responses, -1)
        |> Map.fetch!(:callback)
        |> Kernel.===(nil)

      updated_responses =
        if non_callback_available do
          possible_responses
        else
          Aja.Vector.append(possible_responses, response)
        end

      do_rr(
        rest,
        updated_responses,
        S.Traceback.append(
          traceback,
          responded_log
        )
      )
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
      S.Traceback.append(
        traceback,
        {:plugin_errored, plug, val}
      )
    )
  end

  @spec! decorate_usage(SiteConfig.t(), module()) :: TxtBlock.t()
  def decorate_usage(cfg, plugin) do
    {{:list, :dotted},
     Enum.map(plugin.usage(), fn
       {prompt, response} ->
         [
           {:source, SiteConfig.example_prefix(cfg) <> prompt},
           " ",
           {:bold, "<>"},
           " ",
           {:source, response}
         ]

       other ->
         if S.enable_typechecking?() do
           TypeCheck.conforms!(other, TxtBlock.t())
         else
           other
         end
     end)}
  end
end
