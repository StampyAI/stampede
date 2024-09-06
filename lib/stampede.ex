defmodule Stampede do
  @moduledoc """
  Defines project-wide types and utility functions.
  """
  require Logger
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck

  # Types used across Stampede
  @type! service_name :: module()
  @type! channel_id :: any()
  @typedoc """
  Used in MsgReceived in place of a server ID to denote DM threads
  """
  @type! dm_tuple :: {:dm, service_name()}
  @type! server_id :: integer() | atom() | dm_tuple()
  @type! user_id :: any()
  @type! msg_id :: any()
  @type! prefix :: String.t() | Regex.t()
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

  # Elixir-generic stuff that could/should be builtin types
  @type! module_function_args :: {module(), atom(), tuple() | list()}
  @type! log_level ::
           :emergency | :alert | :critical | :error | :warning | :warn | :notice | :info | :debug
  @type! log_msg ::
           {log_level(), identifier(), {Logger, String.t() | maybe_improper_list(), any(), any()}}
  @type! mapset(t) :: map(any(), t)
  @type! mapset() :: mapset(any())
  @type! kwlist(t) :: list({atom(), t})
  @type! kwlist() :: kwlist(any())
  # BUG: type_check issue #189, iolist()
  #      this stand-in isn't type complete but it'll do
  #      No improper lists allowed
  #      also VERY SLOW to check.
  @type! str_list ::
           String.t()
           | []
           | nonempty_list(lazy(Stampede.str_list()))

  def confused_response(),
    do: {:italics, "confused beeping"}

  def compilation_environment, do: Application.fetch_env!(:stampede, :compile_env)

  def throw_internal_error(text \\ "*screaming*") do
    raise "intentional internal error: #{text}"
  end

  @doc "Check a MsgReceived struct against a SiteConfig whether this author is privileged"
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

  @doc """
  Used for configs to name services when they can't pass real atoms.
  """
  @spec! services() :: map(service_name(), module())
  def services() do
    Application.fetch_env!(:stampede, :installed_services)
    |> Map.new(fn full_atom ->
      {
        full_atom |> downcase_last_atom(),
        full_atom
      }
    end)
  end

  @doc """
      iex> Stampede.downcase_last_atom(Services.Discord)
      :discord
      iex> Stampede.downcase_last_atom(A.B.C)
      :c
  """
  def downcase_last_atom(full_atom) do
    full_atom
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
    |> String.downcase()
    |> String.to_atom()
  end

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
          MapSet.put(acc, List.to_existing_atom(name))
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

  def split_prefix(text, prefix) when is_struct(prefix, Regex) and is_binary(text) do
    case Regex.split(prefix, text, include_captures: true, capture: :first, trim: true) do
      [p, b] ->
        {p, b}

      [^text] ->
        {false, text}

      [] ->
        {false, text}
    end
  end

  def split_prefix(text, prefix) when is_binary(prefix) and is_binary(text) do
    case text do
      # don't match prefix without message
      <<^prefix::binary-size(floor(bit_size(prefix) / 8)), ""::binary>> ->
        {false, text}

      # don't match prefix without message
      <<^prefix::binary-size(floor(bit_size(prefix) / 8)), " "::binary>> ->
        {false, text}

      <<^prefix::binary-size(floor(bit_size(prefix) / 8)), _::binary>> ->
        {
          binary_part(text, 0, byte_size(prefix)),
          binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
        }

      _ ->
        {false, text}
    end
  end

  def split_prefix(text, prefixes) when is_list(prefixes) and is_binary(text) do
    # NOTE: returns at first match, meaning shorter prefixes can mutilate long ones if they come first
    prefixes
    |> Enum.reduce(nil, fn
      _, {s, b} ->
        {s, b}

      p, nil ->
        {s, b} = split_prefix(text, p)
        if s, do: {s, b}, else: nil
    end)
    |> then(fn
      nil ->
        {false, text}

      {s, b} ->
        {s, b}
    end)
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

  @doc """
  chunk text using binary parts which reference the original binary
  """
  def text_chunk(text, len, max_pieces \\ false, premade_regex \\ nil)
      when is_bitstring(text) and is_integer(len) and
             (is_nil(premade_regex) or is_struct(premade_regex, Regex)) do
    r = premade_regex || text_chunk_regex(len)

    Regex.scan(r, text, trim: true, capture: :all_but_first, return: :index)
    |> then(fn x -> if max_pieces, do: Enum.take(x, max_pieces), else: x end)
    |> Enum.map(fn [{i, l}] ->
      # return reference to binary. Regex module has handled unicode already
      binary_part(text, i, l)
    end)
  end

  @doc "Although it may seem like you could split with direct binary accesses, this wouldn't handle unicode characters"
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

  @spec! fulfill_predicate_before_time(DateTime.t(), (-> boolean())) :: :fulfilled | :failed
  def fulfill_predicate_before_time(cutoff, pred) do
    if pred.() do
      :fulfilled
    else
      if DateTime.utc_now() |> DateTime.after?(cutoff) do
        :failed
      else
        fulfill_predicate_before_time(cutoff, pred)
      end
    end
  end

  def ensure_app_ready?() do
    match?({:ok, _}, Application.ensure_all_started(:stampede)) and
      :ok ==
        Memento.wait(
          Stampede.Tables.mnesia_tables(),
          :timer.seconds(5)
        )
  end

  def ensure_app_ready!(),
    do: ensure_app_ready?() || raise("Stampede wouldn't start on time")

  if Application.compile_env!(:stampede, [:type_check, :enable_runtime_checks]) do
    def enable_typechecking?(), do: true
  else
    def enable_typechecking?(), do: false
  end

  def sort_rev_str_len(str_list) do
    Enum.sort(str_list, fn s1, s2 ->
      l1 = String.length(s1)
      l2 = String.length(s2)

      cond do
        l1 > l2 ->
          true

        l1 < l2 ->
          false

        l1 == l2 ->
          s1 <= s2
      end
    end)
  end

  def end_with_newline(unmodified_bin) do
    String.trim_trailing(unmodified_bin)
    |> Kernel.<>("\n")
  end

  def await_process!(name, tries \\ 100)

  def await_process!(name, 0) do
    Logger.error(fn ->
      [
        "Tried to find process ",
        inspect(name),
        " but it never registered."
      ]
    end)

    raise "Process #{inspect(name)} not found"
  end

  def await_process!(name, tries) do
    case Process.whereis(name) do
      nil ->
        Process.sleep(10)
        await_process!(name, tries - 1)

      pid ->
        pid
    end
  end

  def path_exists?(path) do
    if File.exists?(path),
      do: {:ok, path},
      else: {:error, "File not found"}
  end

  defmodule Debugging do
    @moduledoc false
    use TypeCheck

    @spec! always_fails_typecheck() :: :ok
    def always_fails_typecheck() do
      Process.put(:lollollol, :fail)
      Process.get(:lollollol)
    end
  end
end
