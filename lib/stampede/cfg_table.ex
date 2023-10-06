defmodule Stampede.CfgTable do
  use GenServer
  use TypeCheck

  @table :cfg_ets

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def make_filled_table(app_id, config_dir) do
    ets_settings = []
    # ets_settings = [:set, :protected,
    #  tweaks: [
    #    read_concurrency: true,
    #    write_concurrency: false
    #  ]]
    table_id = :ets.new(Module.concat(app_id, @table), ets_settings)

    SiteConfig.load_all(config_dir)
    |> fill_cfg_table(table_id)

    table_id
  end

  def fill_cfg_table(cfgs, table_id) do
    :ets.delete_all_objects(table_id)

    Enum.each(cfgs, fn {_filename, cfg} ->
      data =
        Enum.map(cfg, fn {opt, val} ->
          {{cfg.server_id, opt}, val}
        end)

      :ets.insert_new(table_id, data)
    end)

    :ok
  end

  def init(args) do
    app_id = Keyword.fetch!(args, :app_id)
    config_dir = Keyword.fetch!(args, :config_dir)
    table_id = make_filled_table(app_id, config_dir)
    {:ok, %{table_id: table_id, config_dir: config_dir, app_id: app_id}}
  end

  def lookup(app_id, server_id, key) do
    Module.safe_concat(app_id, @table)
    |> :ets.lookup({server_id, key})
  end

  def reload_cfgs(app_id, dir \\ nil) do
    Module.safe_concat(app_id, "CfgTable")
    |> GenServer.call({:reload_cfgs, dir})
  end

  def handle_call({:reload_cfgs, new_dir}, _from, %{
        table_id: _old,
        config_dir: config_dir,
        app_id: app_id
      }) do
    new_id = make_filled_table(app_id, new_dir || config_dir)
    {:noreply, %{table_id: new_id, config_dir: config_dir, app_id: app_id}}
  end
end
