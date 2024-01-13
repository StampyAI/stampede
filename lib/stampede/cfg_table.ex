defmodule Stampede.CfgTable do
  use GenServer
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(config_dir: _ :: binary())

  @doc "verify table is laid out correctly, basically a type check"
  def valid?(persisted_term) when not is_map(persisted_term),
    do: raise("invalid config table")

  def valid?(persisted_term) when is_map(persisted_term) do
    Enum.reduce(persisted_term, true, fn
      _, false ->
        false

      {service, cfg_map}, true when is_atom(service) and is_map(cfg_map) ->
        Enum.all?(cfg_map, fn
          {server_id, cfg} ->
            TypeCheck.conforms?({server_id, cfg}, {S.server_id(), SiteConfig.t()})
        end)
    end)
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
  Handle creation and population of a new table, and optionally deleting the old one
  """
  def publish_terms(config_dir) do
    table_contents =
      SiteConfig.load_all(config_dir)

    :ok = :persistent_term.put(__MODULE__, table_contents)

    :ok
  end

  @spec! servers_configured() ::
           %MapSet{}
  def servers_configured() do
    :persistent_term.get(__MODULE__)
    |> Map.values()
    |> Enum.map(&Map.keys/1)
    |> MapSet.new()
  end

  @spec! servers_configured(service_name :: S.service_name()) ::
           %MapSet{}
  def servers_configured(service_name) do
    :persistent_term.get(__MODULE__)
    |> Map.fetch!(service_name)
    |> Map.keys()
    |> MapSet.new()
  end

  @spec! reload_cfgs(nil | String.t()) :: :ok
  def reload_cfgs(dir \\ nil) do
    GenServer.call(__MODULE__, {:reload_cfgs, dir})
  end

  @spec! table_dump() :: map()
  def table_dump() do
    :persistent_term.get(__MODULE__)
  end

  def get_server(service, id) do
    :persistent_term.get(__MODULE__)
    |> Map.fetch!(service)
    |> Map.fetch!(id)
  end

  @impl GenServer
  def handle_call({:reload_cfgs, new_dir}, _from, state = %{config_dir: config_dir}) do
    :ok = publish_terms(config_dir)
    {:noreply, state}
  end
end
