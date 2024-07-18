defmodule Stampede.External.Python.Pool do
  @moduledoc false
  use Doumi.Port,
    adapter: {
      Doumi.Port.Adapter.Python,
      python: Application.fetch_env!(:stampede, :python_exe),
      python_path: Application.fetch_env!(:stampede, :python_plugin_dirs)
    },
    pool_size: 4
end

defmodule Stampede.External.Python do
  @moduledoc """
  Run Python functions with [Doumi](https://hexdocs.pm/doumi_port/readme.html).
  When working on the Python side, you should use the Python helpers that Doumi makes available from the [ErlPort](http://erlport.org/docs/python.html) project.
  """
  use TypeCheck
  alias Stampede, as: S
  require S.ResponseToPost
  alias Stampede.External.Python, as: SPy

  def start_link() do
    Supervisor.start_link([SPy.Pool], strategy: :one_for_one, name: SPy.Supervisor)
  end

  @doc """
  Run a Python function and return a result.
  """
  def exec(py_mod, func_atom, args, opts \\ []) do
    SPy.Pool.command(py_mod, func_atom, args, opts)
  end

  @doc """
  An example way to make a ResponseToPost from a Python module response, trying to minimize complications with cross-environment communications.
  Expects the Python module to respond with a Dict containing only keys "confidence", "text", and "why".
  Don't forget you can also make an Elixir plugin that only calls Python as needed, which will be better for tracebacks etc..
  """
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

  @doc """
  A brute-force way to make Elixir objects more generic for easier Python use. Start by checking if the object is a keyword list, which should really be a Dict in Python.
  """
  def dumb_down_elixir_term(term) do
    if TypeCheck.conforms?(term, S.kwlist()) do
      Map.new(term, fn {k, v} -> {Atom.to_string(k), dumb_down_elixir_term(v)} end)
    else
      do_dumb_down_elixir_term(term)
    end
  end

  defp do_dumb_down_elixir_term(term) when is_atom(term), do: Atom.to_string(term)

  defp do_dumb_down_elixir_term(tup) when is_tuple(tup) do
    tup
    |> Tuple.to_list()
    |> Enum.map(&dumb_down_elixir_term/1)
    |> List.to_tuple()
  end

  defp do_dumb_down_elixir_term([h | t]),
    do: [dumb_down_elixir_term(h) | do_dumb_down_elixir_term(t)]

  defp do_dumb_down_elixir_term(ms) when is_struct(ms, MapSet) do
    ms
    |> MapSet.to_list()
    |> Enum.map(fn
      v ->
        dumb_down_elixir_term(v)
    end)
  end

  defp do_dumb_down_elixir_term(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> do_dumb_down_elixir_term()
  end

  defp do_dumb_down_elixir_term(map) when is_map(map) do
    map
    |> Map.new(fn
      {k, v} ->
        {dumb_down_elixir_term(k), dumb_down_elixir_term(v)}
    end)
  end

  defp do_dumb_down_elixir_term(otherwise), do: otherwise
end
