defmodule Stampede.CfgTable do
  use GenServer
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    config_dir: _ :: binary(),
    published_keys: _ :: %MapSet{}
  )

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(keyword()) :: {:ok, map()}
  @impl GenServer
  def init(args) do
    config_dir = Keyword.fetch!(args, :config_dir)
    keys = make_filled_table(config_dir)
    {:ok, struct!(__MODULE__, published_keys: keys, config_dir: config_dir)}
  end

  @doc """
  Handle creation and population of a new table, and optionally deleting the old one
  """
  def make_filled_table(config_dir, old_keys \\ nil) do
    table_contents =
      SiteConfig.load_all(config_dir)
      |> make_table_contents()

    if old_keys != nil do
      table_contents
      |> MapSet.new(fn {k, _v} -> k end)
      |> MapSet.difference(old_keys)
      |> Enum.map(fn key ->
        erased = :persistent_term.erase(key)
        {key, erased}
      end)
      |> Enum.each(fn {key, erased} ->
        if not erased, do: raise("cfg cleanup issue, key: #{inspect(key)}"), else: :ok
      end)
    end

    Enum.each(table_contents, fn {key, value} ->
      :ok = :persistent_term.put(key, value)
    end)

    table_contents
    |> Map.keys()
    |> MapSet.new()
  end

  @doc """
  With given cfgs, creates a schema like this:

    {server_id, :filename}, filename
    # then the rest of the keys:
    {server_id, config_key_1}, config_value_1
    {server_id, config_key_2}, config_value_2
    # etc
  """
  @spec! make_table_contents(SiteConfig.cfg_list()) ::
           map({S.server_id(), atom()}, any())
  def make_table_contents(cfgs) do
    Enum.map(cfgs, &cfg_to_entries/1)
    |> Enum.concat()
    |> Map.new()
  end

  def cfg_to_entries({filename, cfg}), do: cfg_to_entries(filename, cfg)

  @spec! cfg_to_entries(SiteConfig.site_name(), SiteConfig.t()) ::
           list({S.server_id() | {S.server_id(), atom()}, any()})
  def cfg_to_entries(filename, cfg) do
    [
      {{cfg.server_id, :filename}, filename}
      | Enum.map(cfg, fn {opt, val} ->
          {{cfg.server_id, opt}, val}
        end)
    ]
  end

  def lookup(server_id, key),
    do: lookup({server_id, key})

  def lookup(key) do
    case :persistent_term.get(key, :not_found) do
      :not_found ->
        {:error, :not_found}

      item ->
        {:ok, item}
    end
  end

  def lookup!(server_id, key), do: lookup!({server_id, key})

  def lookup!(key) do
    case lookup(key) do
      {:ok, item} ->
        item

      {:error, :not_found} ->
        raise "couldn't find key in CfgTable. key: #{inspect(key)}"
    end
  end

  def member(key) do
    case lookup(key) do
      {:ok, _} ->
        true

      _ ->
        false
    end
  end

  def server_configured?(server_id) do
    member({server_id, :service})
  end

  @spec! servers_configured() ::
           %MapSet{}
  def servers_configured() do
    GenServer.call(__MODULE__, :servers_configured_all)
  end

  @spec! servers_configured(service_name :: S.service_name()) ::
           %MapSet{}
  def servers_configured(service_name) do
    GenServer.call(__MODULE__, {:servers_configured_for_service, service_name})
  end

  @spec! reload_cfgs(nil | String.t()) :: :ok
  def reload_cfgs(dir \\ nil) do
    GenServer.call(__MODULE__, {:reload_cfgs, dir})
  end

  @spec! table_dump() :: map()
  def table_dump() do
    GenServer.call(__MODULE__, :published_keys)
    |> Map.new(fn key ->
      {key, lookup!(key)}
    end)
  end

  def handle_call(:servers_configured_all, _, state) do
    {
      :reply,
      state.published_keys
      |> MapSet.new(fn {server, _item} -> server end),
      state
    }

    # |> TypeCheck.conforms!({:reply, %MapSet{}, %__MODULE__{}})
  end

  def handle_call({:servers_configured_for_service, service}, _, state) do
    return =
      state.published_keys
      |> Enum.reduce(MapSet.new(), fn
        {server, :service}, acc ->
          s = lookup!({server, :service})

          if s == service do
            MapSet.put(acc, server)
          else
            acc
          end

        {_server, _item}, acc ->
          acc
      end)

    {
      :reply,
      return,
      state
    }

    # |> TypeCheck.conforms!({:reply, %MapSet{}, %__MODULE__{}})
  end

  def handle_call(:published_keys, _, state) do
    {
      :reply,
      state.published_keys,
      state
    }

    # |> TypeCheck.conforms!({:reply, %MapSet{}, %__MODULE__{}})
  end

  @impl GenServer
  def handle_call({:reload_cfgs, new_dir}, _from, %{
        table_id: old_table_id,
        config_dir: config_dir
      }) do
    new_id = make_filled_table(new_dir || config_dir, old_table_id)
    {:noreply, %{table_id: new_id, config_dir: config_dir}}
  end
end
