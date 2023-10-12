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

  @spec! failure_summary(any()) :: String.t()
  defp failure_summary({task, {:error, issue}}),
    do: "Task failed: #{inspect(task, pretty: true)}\nError: #{inspect(issue, pretty: true)}"

  defp failure_summary({task, {:exit, {rte, [first_level | _location]}}})
       when is_struct(rte, RuntimeError) do
    loc_details = elem(first_level, 3)

    """
    Task exited: #{inspect(task, pretty: true)}
    It hit a runtime error at file #{loc_details[:file]}, line #{loc_details[:line]}
    It should be logged elsewhere
    """
  end

  defp failure_summary({task, {:exit, reason}}),
    do: "Task exited: #{inspect(task, pretty: true)}\nreason: #{inspect(reason, pretty: true)}"

  defp failure_summary({task, nil}),
    do: "Task failed: #{inspect(task, pretty: true)}\nError: no return"

  defp failure_summary(other),
    do: "failure_summary didn't recognize the task/result tuple: #{inspect(other, pretty: true)}"

  @spec! get_top_response(SiteConfig.t(), Msg.t()) :: nil | Response.t()
  def get_top_response(cfg, msg) do
    plugs =
      __MODULE__.ls(cfg.plugs)

    tasks =
      Task.Supervisor.async_stream_nolink(
        S.quick_task_via(cfg.app_id),
        plugs,
        fn this_plug ->
          # if an error occurs in process_msg, catch it and return as data
          try do
            {:ok, this_plug.process_msg(cfg, msg)}
          rescue
            e ->
              Logger.error(Exception.format(:error, e, __STACKTRACE__))

              {:error, e.__struct__, cfg.service.log_error(cfg, {msg, e, __STACKTRACE__})}
          end
        end,
        timeout: @first_response_timeout,
        on_timeout: :kill_task,
        ordered: true
      )

    task_results =
      Stream.zip([plugs, tasks])
      |> Enum.map(fn
        {plug, {_task, result}} ->
          case result do
            {:ok, success} ->
              if is_struct(success, S.Response) and plug != success.origin_plug do
                raise(
                  "Plug #{plug} doesn't match #{success.origin_plug}. I screwed up the task running code."
                )
              end

              {plug, {:ok, success}}

            :timeout ->
              {plug, :timeout}
              # should never get :exit since we're catching
          end
      end)

    final_responses =
      Enum.reduce(task_results, [], fn result, acc ->
        case result do
          {_plug, {:ok, result}} ->
            if result == nil,
              do: acc,
              else: [result | acc]

          _ ->
            acc
        end
      end)
      |> Response.sort()

    case final_responses do
      [] ->
        nil

      successes when is_list(successes) ->
        chosen = hd(successes)
        why_others = Plugin.Why.tried_plugs(task_results)
        Map.put(chosen, :why, why_others)
    end

    # TODO: callbacks, and traceback appends
  end
end

defmodule Plugin.Why do
  use TypeCheck
  require Logger
  # alias Stampede, as: S
  # alias S.{Msg,Response}

  def tried_plugs(task_results) do
    Enum.reduce(task_results, [], fn
      {plug, {:ok, nil}}, acc ->
        [acc | "\nWe asked #{plug}, and it decided not to answer."]

      {plug, :timeout}, acc ->
        [acc | "\nWe asked #{plug}, but it timed out."]

      {plug, {:ok, response}}, acc ->
        [
          acc
          | "\nWe asked #{plug}, and it responded with:\n\"#{response.text}\"\nWhen asked why, it said: \"#{response.why}\""
        ]

      {plug, {:error, val, _trace_location}}, acc ->
        [
          acc
          | "\nWe asked #{plug}, but there was an error of type #{val.__struct__}, message #{val.message}"
        ]
    end)
    |> IO.iodata_to_binary()
  end
end
