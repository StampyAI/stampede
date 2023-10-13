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
        {task_ids[task.ref], result || Task.shutdown(task, :brutal_kill)}
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
  alias Stampede, as: S
  # alias S.{Msg,Response}

  def tried_plugs(task_results) do
    Enum.reduce(task_results, [], fn
      {plug, {:ok, nil}}, acc ->
        [acc | "\nWe asked #{plug}, and it decided not to answer."]

      {plug, {:error, :timeout}}, acc ->
        [acc | "\nWe asked #{plug}, but it timed out."]

      {plug, {:ok, response}}, acc ->
        quoted_response =
          S.markdown_quote(response.text)

        [
          acc
          | "\nWe asked #{plug}, and it responded with confidence #{response.confidence}:\n#{quoted_response}\nWhen asked why, it said: \"#{response.why}\""
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
