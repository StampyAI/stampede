defmodule Plugin do
  use TypeCheck
  require Logger
  alias Stampede, as: S
  alias S.{Msg,Response}
  @first_response_timeout 500
  @callback process_message(SiteConfig.t(), Msg.t()) :: nil | Response.t()

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
  defp failure_summary({task, {:exit, {rte, [first_level | _location]}}}) when is_struct(rte, RuntimeError) do 
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
  defp failure_summary(other), do: "failure_summary didn't recognize the task/result tuple: #{inspect(other, pretty: true)}"
  @spec! get_top_response(SiteConfig.t(), Msg.t()) :: nil | Response.t()
  def get_top_response(cfg, msg) do
    result_list = __MODULE__.ls(cfg.plugs)
    |> Enum.map(&Task.Supervisor.async_nolink(
        S.quick_task_via(cfg.app_id), &1, :process_msg, [cfg, msg]))
    |> Task.yield_many(timeout: @first_response_timeout, on_timeout: :kill_task)
    |> Enum.reduce([], fn result, acc -> 
        case result do
          {_task, {:ok, result}} ->
            if result == nil, do: acc,
                else: [result | acc]
          other -> 
            Logger.error(failure_summary(other))
            acc
        end
    end)
    |> Response.sort()
    case result_list do
      [] -> nil
      successes when is_list(successes) ->
        hd(successes)
    end
    # TODO: callbacks, and traceback appends
  end
end
