defmodule Stampede.Logger do
  @moduledoc """
  Listens for global errors raised from Erlang's logger system. If an error gets thrown in this module or children it would cause an infinite loop.
  """

  use TypeCheck
  @behaviour :gen_event
  # alias Stampede, as: S
  @type! logger_state :: Keyword.t()

  def start_link() do
    :gen_event.start_link({:local, __MODULE__})
  end

  @impl :gen_event
  @spec! init(any()) :: {:ok, logger_state()}
  def init(_) do
    backend_env = [level: Application.get_env(:logger, __MODULE__, :warning)]
    {:ok, backend_env}
  end

  @impl :gen_event
  @spec! handle_event(any(), logger_state()) :: {:ok, logger_state()}
  def handle_event(log_msg = {level, gl, {Logger, _message, _timestamp, _metadata}}, state)
      when node(gl) == node() do
    case Logger.compare_levels(level, state[:level]) do
      :lt ->
        nil

      _ ->
        _ = Service.log_serious_error(log_msg)
    end

    {:ok, state}
  end

  # NOTE: mandatory default handler, removing will crash
  def handle_event({_, gl, {_, _, _, _}}, state)
      when node(gl) != node(),
      do: {:ok, state}

  def handle_event(_, state), do: {:ok, state}

  @impl :gen_event
  def handle_call({:configure, options}, state) do
    {:ok, :ok, Keyword.merge(state, options)}
  end
end
