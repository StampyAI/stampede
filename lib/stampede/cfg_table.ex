defmodule Stampede.CfgTable do
  use GenServer
  require Logger
  alias Stampede, as: S
  use TypeCheck
  use TypeCheck.Defstruct

  defstruct!(config_dir: _ :: binary())

  @type! vips :: map(server_id :: S.server_id(), author_id :: S.user_id())
  @type! table_object :: map(S.service_name(), map(S.server_id(), SiteConfig.t()))

  @doc "verify table is laid out correctly, basically a type check"
  def valid?(persisted_term) do
    TypeCheck.conforms?(persisted_term, Stampede.CfgTable.table_object())
  end

  def valid!(persisted_term) do
    if valid?(persisted_term) do
      persisted_term
    else
      raise "Invalid config\n" <> S.pp(persisted_term)
    end
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
           %MapSet{}
  def servers_configured() do
    try_with_table(fn table ->
      table
      |> Map.values()
      |> Enum.map(&Map.keys/1)
      |> MapSet.new()
    end)
  end

  @spec! servers_configured(service_name :: S.service_name()) ::
           %MapSet{}
  def servers_configured(service_name) do
    try_with_table(fn table ->
      table
      |> Map.get(service_name, %{})
      |> tap(fn
        %{} -> Logger.warning("No servers detected for #{Atom.to_string(service_name)}")
        m when is_map(m) -> :ok
      end)
      |> Map.keys()
      |> Enum.map(fn cfg -> cfg.server_id end)
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

    :persistent_term.put(__MODULE__, contents)
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
    Logger.info("adding #{cfg.service} server #{cfg.server_id}")

    schema = apply(cfg.service, :site_config_schema, [])
    _ = SiteConfig.revalidate!(cfg, schema)

    table_dump()
    |> Map.put_new(cfg.service, %{})
    |> Map.update!(cfg.service, fn cfgs ->
      Map.put(cfgs, cfg.server_id, cfg)
    end)
    |> IO.inspect(pretty: true)
    |> :persistent_term.put(__MODULE__)

    Process.sleep(100)

    S.reload_service(cfg)
  end

  @impl GenServer
  def handle_call({:reload_cfgs, new_dir}, _from, state = %{config_dir: _config_dir}) do
    :ok = publish_terms(new_dir)

    table_dump()
    |> Map.values()
    |> Enum.map(&Map.values/1)
    |> List.flatten()
    |> Enum.each(&S.reload_service/1)

    {:noreply, state |> Map.put(:config_dir, new_dir)}
  end
end
