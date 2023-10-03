defmodule Stampede do
  use TypeCheck
  @type! channel_id :: any() #Service.Discord.discord_channel_id() | Service.Dummy.dummy_channel_id()
  @type! server_id :: any() #Service.Discord.discord_guild_id() | Service.Dummy.dummy_server_id()
  @type! user_id :: any() #Service.Discord.discord_user_id() | Service.Dummy.dummy_user_id()
  @type! log_level :: :emergency | :alert | :critical | :error | :warning | :warn | :notice | :info | :debug
  @type! log_msg :: {log_level(), identifier(), {Logger, String.t() | maybe_improper_list(), any(), any()}}
  @type! prefix :: String.t() | Regex.t()
  @type! module_function_args :: {module(), function(), tuple()}
  @type! traceback :: [] | maybe_improper_list(String.t(), []) # BUG: type_check issue #189, iolist()
  @type! enabled_plugs :: :all | [] | nonempty_list(module())

  @doc "use TypeCheck types in NimpleOptions, takes type expressions like @type!"
  defmacro ntc(type) do
    quote do
    {:custom, TypeCheck, :dynamic_conforms,
        [TypeCheck.Type.build(unquote(type))]}
    end
  end
  def quick_task_via(app_id) do
    {:via, PartitionSupervisor,
      {Module.safe_concat(app_id, QuickTaskSupers), self()}}
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
    If passed a text prefix, will match `^prefix(.*)`. If passed regex, will match whatever was given.
  """
  @spec! strip_prefix(String.t() | Regex.t(), String.t()) :: false | String.t()
  def strip_prefix(prefix, text) do
    rex = if not is_struct(prefix, Regex) do
      Regex.compile!("^" <> prefix <> "(.*)")
    else
      prefix
    end
    case Regex.run(rex, text) do
      nil -> false
      [ _p, body ] -> body
    end
  end
  ### "smart" solution
  #def strip_prefix(prefix, msg) when binary_part(msg, 0, floor(bit_size(prefix) / 8)) == prefix do
  #  binary_part(msg, floor(bit_size(prefix) / 8), floor((bit_size(msg) - bit_size(prefix)) / 8))
  #end
end
