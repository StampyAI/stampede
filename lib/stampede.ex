defmodule Stampede do
  use TypeCheck
  @type! channel_id :: any()
  @type! server_id :: integer() | atom() | {:dm, lazy(server_id())}
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
  @type! timestamp :: String.t()
  @type! service_name :: atom()
  @type! interaction_id :: non_neg_integer()

  def confused_response(),
    do: "*confused beeping*"

  def throw_internal_error(msg \\ "*screaming*") do
    raise "intentional internal error: #{msg}"
  end

  @spec! author_privileged?(
           %{server_id: any()},
           %{author_id: any()}
         ) :: boolean()
  def author_privileged?(cfg, msg) do
    Service.apply_service_function(cfg, :author_privileged?, [cfg.server_id, msg.author_id])
  end

  @spec! vip_in_this_context?(map(), server_id(), user_id()) :: boolean()
  def vip_in_this_context?(vips, nil, author_id),
    do: author_id in Map.values(vips)

  def vip_in_this_context?(vips, server_id, author_id) do
    Enum.any?(vips, fn {this_server, this_author} ->
      author_id == this_author and this_server == server_id
    end)
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

  def text_chunk(msg, len, max_pieces, premade_regex \\ nil)
      when is_bitstring(msg) and is_integer(len) and is_integer(max_pieces) and
             (is_nil(premade_regex) or is_struct(premade_regex, Regex)) do
    r = premade_regex || text_chunk_regex(len)

    Regex.scan(r, msg, trim: true, capture: :all_but_first)
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
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  def pp(thing) do
    inspect(thing, pretty: true)
  end

  def reload_service(cfg) do
    Service.apply_service_function(cfg, :reload_configs, [])
  end
end
