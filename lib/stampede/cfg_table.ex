defmodule Stampede.CfgTable do
  use GenServer
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    config_dir: _ :: binary(),
    table_id: _ :: any()
  )

  def table() do
    __MODULE__
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec! init(keyword()) :: {:ok, map()}
  @impl GenServer
  def init(args) do
    config_dir = Keyword.fetch!(args, :config_dir)
    table_id = make_filled_table(config_dir)
    {:ok, struct!(__MODULE__, table_id: table_id, config_dir: config_dir)}
  end

  @doc """
  Handle creation and population of a new table, and optionally deleting the old one
  """
  def make_filled_table(config_dir, old_table \\ nil) do
    ets_settings = [:named_table]
    # ets_settings = [:set, :protected,
    #  tweaks: [
    #    read_concurrency: true,
    #    write_concurrency: false
    #  ]]
    table_contents =
      SiteConfig.load_all(config_dir)
      |> make_table_contents()

    if old_table, do: :ets.delete(old_table)
    table_id = :ets.new(table(), ets_settings)
    true = :ets.insert_new(table_id, table_contents)

    table_id
  end

  @doc """
  With given cfgs, creates a schema like this:

    server_id, {service, filename}
    {server_id, config_key_1}, config_value_1
    {server_id, config_key_2}, config_value_2
  """
  @spec! make_table_contents(SiteConfig.cfg_list()) ::
           list({S.server_id() | {S.server_id(), atom()}, any()})
  def make_table_contents(cfgs) do
    Stream.map(cfgs, &cfg_to_entries/1)
    |> Enum.concat()
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
    table()
    |> :ets.lookup(key)
    # Assuming no duplicate keys
    |> case do
      lst = [{_key, item}] when length(lst) == 1 ->
        {:ok, item}

      lst when is_list(lst) and length(lst) > 1 ->
        raise "there shouldn't be multiple keys, this is a set database"

      [] ->
        {:error, :not_found}
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

  def server_configured?(server_id) do
    table()
    |> :ets.member({server_id, :service})
  end

  def servers_configured(service_name) do
    table()
    |> :ets.match({{:"$1", :service}, service_name})
    |> MapSet.new(&hd(&1))
  end

  def reload_cfgs(dir \\ nil) do
    table()
    |> GenServer.call({:reload_cfgs, dir})
  end

  def table_dump() do
    table()
    |> :ets.tab2list()
    |> Map.new()
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
