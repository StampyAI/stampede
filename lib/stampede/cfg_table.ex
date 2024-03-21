defmodule Stampede.CfgTable do
  use GenServer
  require Logger
  alias Stampede, as: S
  use TypeCheck
  use TypeCheck.Defstruct

  @type! vips :: map(server_id :: S.server_id(), author_id :: S.user_id())
  @type! table_object :: map(S.service_name(), map(S.server_id(), SiteConfig.t()))

  defstruct!(config_dir: _ :: binary())

  @doc "verify table is laid out correctly, basically a type check"
  def valid?(persisted_term) when not is_map(persisted_term),
    do: false

  def valid?(persisted_term) when is_map(persisted_term) do
    Enum.reduce(persisted_term, true, fn
      _, false ->
        false

      {service, cfg_map}, true when is_atom(service) and is_map(cfg_map) ->
        Enum.all?(cfg_map, fn
          {server_id, cfg} ->
            TypeCheck.conforms?({server_id, cfg}, {S.server_id(), SiteConfig.t()})
        end)

      _, true ->
        false
    end)
  end

  def valid!(persisted_term) do
    if valid?(persisted_term) do
      persisted_term
    else
      raise "Invalid config follows:\n" <> S.pp(persisted_term)
    end
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @spec! init(keyword()) :: {:ok, %__MODULE__{}}
  @impl GenServer
  def init(args) do
    config_dir = Keyword.fetch!(args, :config_dir)
    :ok = publish_terms(config_dir)
    {:ok, struct!(__MODULE__, config_dir: config_dir)}
  end

  @doc """
  Handle creation and population of a new table, and deleting the old one
  """
  def publish_terms(config_dir) do
    table_contents =
      SiteConfig.load_all(config_dir)

    :ok = table_load(table_contents)

    :ok
  end

  @spec! servers_configured() ::
           MapSet.t(S.server_id())
  def servers_configured() do
    try_with_table(fn table ->
      table
      |> Map.values()
      |> Enum.flat_map(fn service ->
        Enum.map(service, &SiteConfig.fetch!(&1, :server_id))
      end)
      |> MapSet.new()
    end)
  end

  @spec! servers_configured(service_name :: S.service_name()) ::
           MapSet.t(S.server_id())
  def servers_configured(service_name) do
    try_with_table(fn table ->
      table
      |> Map.get(service_name, %{})
      |> tap(fn
        m when is_map(m) and map_size(m) == 0 ->
          Logger.warning(
            "No servers detected for #{inspect(service_name)}\nTable: #{S.pp(table)}"
          )

        m when is_map(m) ->
          :ok
      end)
      |> Map.values()
      |> Enum.map(&SiteConfig.fetch!(&1, :server_id))
      |> MapSet.new()
    end)
  end

  @spec! vips_configured(service_name :: S.service_name()) :: vips()
  def vips_configured(service_name) do
    try_with_table(fn table ->
      do_vips_configured(table, service_name)
    end)
  end

  @spec! do_vips_configured(map(), S.server_id()) :: vips()
  def do_vips_configured(cfg_table, service_name) do
    cfg_table
    |> Map.get(service_name, %{})
    |> Map.values()
    |> Enum.reduce(Map.new(), fn
      cfg, vips ->
        case Map.get(cfg, :vip_ids, false) do
          false ->
            vips

          more_vips when is_struct(more_vips, MapSet) ->
            Map.update(
              vips,
              SiteConfig.fetch!(cfg, :server_id),
              more_vips,
              fn existing_vips -> MapSet.union(more_vips, existing_vips) end
            )
        end
    end)
  end

  @spec! reload_cfgs(nil | String.t()) :: :ok
  def reload_cfgs(dir \\ nil) do
    GenServer.call(__MODULE__, {:reload_cfgs, dir})
  end

  @spec! table_dump() :: table_object()
  def table_dump() do
    :persistent_term.get(__MODULE__)
  end

  @spec! table_load(table_object()) :: :ok
  def table_load(contents) do
    valid!(contents)

    :ok = :persistent_term.put(__MODULE__, contents)
  end

  def try_with_table(f) do
    table = table_dump()

    try do
      f.(table)
    catch
      _t, _e ->
        reraise(
          """
          Standard action with config failed. Now dumping state for examination.
          If the error isn't caught, it will get raised after this.
          """ <>
            S.pp(table),
          __STACKTRACE__
        )
    end
  end

  @spec! get_cfg!(S.service_name(), S.server_id()) :: SiteConfig.t()
  def get_cfg!(service, id) do
    table_dump()
    |> Map.fetch!(service)
    |> Map.fetch!(id)
  end

  @doc """
  Insert new server config while running. Will be lost at reboot.
  """
  def insert_cfg(cfg) do
    Logger.info("adding #{cfg.service |> inspect()} server #{cfg.server_id |> inspect()}")

    schema = Service.apply_service_function(cfg, :site_config_schema, [])
    _ = SiteConfig.revalidate!(cfg, schema)

    try_with_table(fn table ->
      table
      |> Map.put_new(cfg.service, %{})
      |> Map.update!(cfg.service, fn cfgs ->
        Map.put(cfgs, cfg.server_id, cfg)
      end)
      |> table_load()
    end)

    Process.sleep(100)

    S.reload_service(cfg)
  end

  @impl GenServer
  def handle_call({:reload_cfgs, new_dir}, _from, state = %{config_dir: _config_dir}) do
    :ok = publish_terms(new_dir)

    try_with_table(fn table ->
      table
      |> Map.values()
      |> Enum.map(&Map.values/1)
      |> List.flatten()
      |> Enum.each(&S.reload_service/1)
    end)

    {:noreply, state |> Map.put(:config_dir, new_dir)}
  end
end
