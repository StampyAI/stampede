defmodule Stampede do
  use TypeCheck
  @type! channel_id :: any()
  @type! server_id :: any()
  @type! user_id :: any()
  @type! log_level ::
           :emergency | :alert | :critical | :error | :warning | :warn | :notice | :info | :debug
  @type! log_msg ::
           {log_level(), identifier(), {Logger, String.t() | maybe_improper_list(), any(), any()}}
  @type! prefix :: String.t() | Regex.t()
  @type! module_function_args :: {module(), atom(), tuple() | list()}
  # BUG: type_check issue #189, iolist()
  @type! traceback :: String.t() | [] | maybe_improper_list(String.t(), [])
  @type! enabled_plugs :: :all | [] | nonempty_list(module())

  @doc "use TypeCheck types in NimpleOptions, takes type expressions like @type!"
  defmacro ntc(type) do
    quote do
      {:custom, TypeCheck, :dynamic_conforms, [TypeCheck.Type.build(unquote(type))]}
    end
  end

  @spec markdown_quote(String.t()) :: String.t()
  def markdown_quote(str) when is_binary(str) do
    String.split(str, "\n")
    |> Enum.map(&["> " | [&1 | "\n"]])
    |> IO.iodata_to_binary()
  end

  def via(key) do
    {:via, Registry, {Stampede.Registry, key}}
  end

  def quick_task_via() do
    {:via, PartitionSupervisor, {Stampede.QuickTaskSupers, self()}}
  end

  def services(),
    do: %{
      discord: Service.Discord,
      dummy: Service.Dummy
    }

  def service_atom_to_name(atom) do
    services()
    |> Map.fetch!(atom)
  end

  @doc "get a list of submodule atoms"
  @spec! find_submodules(module()) :: MapSet.t(module())
  def find_submodules(module_name) do
    :code.all_available()
    |> Enum.map(&(elem(&1, 0) |> to_string))
    |> Enum.filter(&String.starts_with?(&1, to_string(module_name) <> "."))
    |> Enum.sort()
    |> Enum.map(&String.to_atom/1)
    |> MapSet.new()
  end

  @doc """
  If passed a text prefix, will match the start of the string. If passed a
  regex, it will match whatever was given and return the first match group.
  """
  @spec! strip_prefix(String.t() | Regex.t(), String.t()) :: false | String.t()
  def strip_prefix(prefix, msg)
      ## here comes the "smart" """optimized""" solution
      when is_binary(prefix) and
             binary_part(msg, 0, floor(bit_size(prefix) / 8)) == prefix do
    binary_part(msg, floor(bit_size(prefix) / 8), floor((bit_size(msg) - bit_size(prefix)) / 8))
  end

  def strip_prefix(prefix, msg)
      when is_binary(prefix) and
             binary_part(msg, 0, floor(bit_size(prefix) / 8)) != prefix,
      do: false

  def strip_prefix(rex, text) when is_struct(rex, Regex) do
    case Regex.run(rex, text) do
      nil -> false
      [_p, body] -> body
    end
  end

  @spec! if_then(any(), any(), (any() -> any())) :: any()
  def if_then(value, condition, func) do
    if condition do
      func.(value)
    else
      value
    end
  end

  @spec! keyword_put_new_if_not_falsy(keyword(), atom(), any()) :: keyword()
  def keyword_put_new_if_not_falsy(kwlist, key, new_value) do
    if new_value do
      Keyword.put_new(kwlist, key, new_value)
    else
      kwlist
    end
  end

  def confused_response(),
    do: "*confused beeping*"
end

defmodule Stampede.Interaction do
  alias Stampede.{Msg, Response}
  use TypeCheck
  use TypeCheck.Defstruct

  defstruct!(
    initial_msg: nil :: Msg,
    chosen_response: nil :: nil | Response,
    traceback: [] :: iodata() | String.t()
  )
end
