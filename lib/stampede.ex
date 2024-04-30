defmodule Stampede do
  use TypeCheck
  @type! service_name :: module()
  @type! channel_id :: any()
  @typedoc """
  Used in S.Msg in place of a server ID to denote DM threads
  """
  @type! dm_tuple :: {:dm, service_name()}
  @type! server_id :: integer() | atom() | dm_tuple()
  @type! user_id :: any()
  @type! msg_id :: any()
  @type! log_level ::
           :emergency | :alert | :critical | :error | :warning | :warn | :notice | :info | :debug
  @type! log_msg ::
           {log_level(), identifier(), {Logger, String.t() | maybe_improper_list(), any(), any()}}
  @type! prefix :: String.t() | Regex.t()
  @type! module_function_args :: {module(), atom(), tuple() | list()}
  # BUG: type_check issue #189, iolist()
  #      this stand-in isn't type complete but it'll do
  @type! str_list ::
           String.t()
           | []
           | nonempty_list(lazy(Stampede.str_list()))

  @type! traceback :: TxtBlock.t()
  @type! enabled_plugs :: :all | [] | nonempty_list(module())
  @type! channel_lock_action ::
           false | {:lock, channel_id(), module_function_args()} | {:unlock, channel_id()}
  @type! channel_lock_status ::
           false | {module_function_args(), atom(), integer()}
  @type! timestamp :: DateTime.t()
  @type! interaction_id :: non_neg_integer()

  @type! bot_invoked_status ::
           nil
           | :mentioned_from_service
           | :prefixed

  def confused_response(),
    do: {:italics, "confused beeping"}

  @stampede_compile_env Mix.env()
  def compilation_environment,
    do: @stampede_compile_env

  def throw_internal_error(text \\ "*screaming*") do
    raise "intentional internal error: #{text}"
  end

  @doc "Check a Msg struct against a SiteConfig whether this author is privileged"
  @spec! author_privileged?(
           %{server_id: any()},
           %{author_id: any()}
         ) :: boolean()
  def author_privileged?(cfg, msg) do
    Service.apply_service_function(cfg, :author_privileged?, [cfg.server_id, msg.author_id])
  end

  @doc "generic function for checking one or all servers whether a user is a VIP"
  @spec! vip_in_this_context?(map(), server_id() | :all, user_id()) :: boolean()
  def vip_in_this_context?(vips, :all, author_id),
    do: Map.values(vips) |> Enum.any?(&(author_id in &1))

  def vip_in_this_context?(vips, server_id, author_id) do
    author_id in Map.fetch!(vips, server_id)
  end

  @doc "use TypeCheck types in NimpleOptions, takes type expressions same as @type!"
  defmacro ntc(type) do
    quote do
      {:custom, TypeCheck, :dynamic_conforms, [TypeCheck.Type.build(unquote(type))]}
    end
  end

  def quick_task_via() do
    {:via, PartitionSupervisor, {Stampede.QuickTaskSupers, self()}}
  end

  @spec! services() :: map(service_name(), module())
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
    |> Enum.reduce(MapSet.new(), fn
      {name, _location, _loaded}, acc ->
        name
        |> List.to_string()
        |> String.starts_with?(to_string(module_name) <> ".")
        |> if do
          MapSet.put(acc, List.to_atom(name))
        else
          acc
        end
    end)
  end

  @doc """
  If passed a text prefix, will match the start of the string. If passed a
  regex, it will match whatever was given and return the first match group.
  """
  @spec! strip_prefix(String.t() | Regex.t(), String.t()) :: false | String.t()
  def strip_prefix(prefix, text)
      ## here comes the "smart" """optimized""" solution
      when is_binary(prefix) and
             binary_part(text, 0, floor(bit_size(prefix) / 8)) == prefix do
    binary_part(text, floor(bit_size(prefix) / 8), floor((bit_size(text) - bit_size(prefix)) / 8))
  end

  def strip_prefix(prefix, text)
      when is_binary(prefix) and
             binary_part(text, 0, floor(bit_size(prefix) / 8)) != prefix,
      do: false

  def strip_prefix(rex, text) when is_struct(rex, Regex) do
    case Regex.run(rex, text) do
      nil -> false
      [_p, body] -> body
    end
  end

  def split_prefix(text, prefix) when is_binary(prefix) and is_binary(text) do
    case text do
      <<^prefix::binary-size(floor(bit_size(prefix) / 8)), rest::binary>> ->
        {prefix, rest}

      not_prefixed ->
        {false, not_prefixed}
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

  def text_chunk(text, len, max_pieces, premade_regex \\ nil)
      when is_bitstring(text) and is_integer(len) and is_integer(max_pieces) and
             (is_nil(premade_regex) or is_struct(premade_regex, Regex)) do
    r = premade_regex || text_chunk_regex(len)

    Regex.scan(r, text, trim: true, capture: :all_but_first)
    |> Enum.take(max_pieces)
    |> Enum.map(&hd/1)
  end

  def text_chunk_regex(len) when is_integer(len) and len > 0 do
    Regex.compile!("(.{1,#{len}})", "us")
  end

  def random_string_weak(bytes) do
    :rand.bytes(bytes)
    |> Base.encode64()
    |> String.slice(0..(bytes - 1))
  end

  def file_exists(path) do
    case File.stat(path) do
      {:ok, _} ->
        true

      {:error, :enoent} ->
        false

      {:error, e} ->
        {:error, e}
    end
  end

  def nodes() do
    [node()]
  end

  @spec! time() :: timestamp()
  def time() do
    DateTime.utc_now()
  end

  def pp(thing) do
    inspect(thing, pretty: true)
  end

  def reload_service(cfg) do
    Service.apply_service_function(cfg, :reload_configs, [])
  end

  def make_dm_tuple(service_name), do: {:dm, service_name}

  @type! mapset(t) :: map(any(), t)
  @type! mapset() :: mapset(any())
end
