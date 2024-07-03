defmodule Stampede.PluginForeign.Python.Pool do
  @moduledoc false
  use Doumi.Port,
    adapter: {Doumi.Port.Adapter.Python, python_path: ["./lib_py"]},
    pool_size: 4
end

defmodule Stampede.PluginForeign.Python do
  @moduledoc false
  alias Stampede, as: S
  require S.ResponseToPost
  alias Stampede.PluginForeign.Python, as: SPy

  def start_link() do
    Supervisor.start_link([SPy.Pool], strategy: :one_for_one, name: SPy.Supervisor)
  end

  def query(py_mod, real_cfg, real_event) do
    cfg = dumb_down_elixir_term(real_cfg)
    event = dumb_down_elixir_term(real_event)

    with {:ok, result} <- SPy.Pool.command(py_mod, :process, [cfg, event]) do
      case result do
        :undefined ->
          nil

        %{
          confidence: _confidence,
          text: _text,
          why: _why
        } = basic_info ->
          basic_info
          |> Map.update!(:confidence, fn
            i when is_number(i) ->
              i

            str when is_binary(str) ->
              String.to_float(str)

            [h | _] = cl when is_integer(h) ->
              List.to_float(cl)
          end)
          |> Map.update!(:text, fn
            str when is_binary(str) ->
              str

            [h | _] = cl when is_integer(h) ->
              List.to_string(cl)
          end)
          |> Map.update!(:why, fn
            str when is_binary(str) ->
              str

            [h | _] = cl when is_integer(h) ->
              List.to_string(cl)
          end)
          |> Map.put(:origin_plug, "Python.#{py_mod}" |> String.to_atom())
          |> Map.put(:origin_msg_id, event.msg_id)
          |> Map.to_list()
          |> S.ResponseToPost.new_bare()

        other ->
          raise("""
          Can only handle response as a dict with the keys "confidence", "text" and "why".
          Response given: #{S.pp(other)}
          """)
      end
    end
  end

  def dumb_down_elixir_term(term) when is_atom(term), do: Atom.to_string(term)
  def dumb_down_elixir_term({k, v}), do: {dumb_down_elixir_term(k), dumb_down_elixir_term(v)}
  def dumb_down_elixir_term([h | t]), do: [dumb_down_elixir_term(h) | dumb_down_elixir_term(t)]

  def dumb_down_elixir_term(ms) when is_struct(ms, MapSet) do
    ms
    |> MapSet.to_list()
    |> Enum.map(fn
      v ->
        dumb_down_elixir_term(v)
    end)
  end

  def dumb_down_elixir_term(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> dumb_down_elixir_term()
  end

  def dumb_down_elixir_term(map) when is_map(map) do
    map
    |> Map.new(fn
      {k, v} ->
        {dumb_down_elixir_term(k), dumb_down_elixir_term(v)}
    end)
  end

  def dumb_down_elixir_term(otherwise), do: otherwise
end
