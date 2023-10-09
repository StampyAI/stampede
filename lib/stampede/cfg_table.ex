defmodule Stampede.CfgTable do
  use GenServer
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    app_id: _ :: atom() | binary(),
    config_dir: _ :: binary(),
    table_id: _ :: any()
  )

  def table(app_id) do
    Module.concat(app_id, :cfg_table)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Handle creation and population of a new table, and optionally deleting the old one
  """
  def make_filled_table(app_id, config_dir, old_table \\ nil) do
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
    table_id = :ets.new(table(app_id), ets_settings)
    true = :ets.insert_new(table_id, table_contents)

    table_id
  end

  @doc """
  With given cfgs, creates a schema like this:

    server_id, filename
    {server_id, config_key_1}, config_value_1
    {server_id, config_key_2}, config_value_2
  """
  @spec! make_table_contents(SiteConfig.cfg_list()) ::
           list({S.server_id() | {S.server_id(), atom()}, any()})
  def make_table_contents(cfgs) do
    Stream.map(cfgs, fn {filename, cfg} ->
      [{cfg.server_id, filename}] ++
        Stream.map(cfg, fn {opt, val} ->
          {{cfg.server_id, opt}, val}
        end)
    end)
    |> Enum.concat()
  end

  @spec! init(keyword()) :: {:ok, __MODULE__}
  @impl GenServer
  def init(args) do
    app_id = Keyword.fetch!(args, :app_id)
    config_dir = Keyword.fetch!(args, :config_dir)
    table_id = make_filled_table(app_id, config_dir)
    {:ok, struct!(__MODULE__, table_id: table_id, config_dir: config_dir, app_id: app_id)}
  end

  def lookup(app_id, server_id, key) do
    table(app_id)
    |> :ets.lookup({server_id, key})
    # Assuming no duplicate keys
    |> hd()
  end

  def server_configured?(app_id, server_id) do
    table(app_id)
    |> :ets.member(server_id)
  end

  def reload_cfgs(app_id, dir \\ nil) do
    table(app_id)
    |> GenServer.call({:reload_cfgs, dir})
  end

  @impl GenServer
  def handle_call({:reload_cfgs, new_dir}, _from, %{
        table_id: old_table_id,
        config_dir: config_dir,
        app_id: app_id
      }) do
    new_id = make_filled_table(app_id, new_dir || config_dir, old_table_id)
    {:noreply, %{table_id: new_id, config_dir: config_dir, app_id: app_id}}
  end
end
