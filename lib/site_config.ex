defmodule SiteConfig do
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  @yaml_opts [:plain_as_atom]

  @type! service :: atom()
  @type! server_id :: S.server_id()
  @type! channel_id :: S.channel_id()
  defstruct!(
    service: _ :: service(),
    server_id: _ :: server_id(),
    error_channel_id: _ :: channel_id(),
    prefix: "!" :: Regex.t() | String.t(),
    plugs: :all :: %MapSet{} | :all | MapSet.t(atom())
  )
  @type! site_name :: atom()
  @type! cfg_list :: map(site_name(), SiteConfig.t())

  @spec! load_from_string(String.t()) :: SiteConfig.t()
  def load_from_string(yml) do
    decoded = case :fast_yaml.decode(yml, @yaml_opts) do
      {:ok, [result]} -> Map.new(result)
      {:error, reason} -> raise("bad yaml from string\n#{reason}")
    end
    decoded = if is_list(Map.get(decoded, :plugs)) do
      Map.update!(decoded, :plugs, fn plugs -> 
        case plugs do
          :all -> :all
          ll when is_list(ll) -> 
            Enum.map(ll, &Module.safe_concat(Plugin, &1))
            |> MapSet.new()
        end
      end)
    end
    struct!(
      __MODULE__,
      decoded
    )
  end
  @spec! load(String.t()) :: SiteConfig.t()
  def load(path) do
    decoded = case :fast_yaml.decode_from_file(path, @yaml_opts) do
      {:ok, [result]} -> result
      {:error, reason} -> raise("bad yaml at #{path}\n#{reason}")
    end
    struct!(
      __MODULE__,
      decoded
    )
  end
  @spec! load_all(String.t()) :: cfg_list()
  def load_all(dir) do
    :ok = Application.start(:fast_yaml)
    Path.wildcard(dir <> "/*")
    |> Enum.map(fn path -> 
      site_name = String.to_atom(Path.basename(path, ".yml"))
      config = load(path)
      {site_name, config}
    end)
    |> Enum.into(%{})
  end
  ### I assumed this was a nice convenience, but it disables compile-time checks :/
  #@spec! new(keyword()) :: SiteConfig.t()
  #def new(keys) do
  #  struct!(
  #    __MODULE__,
  #    keys
  #  )
  #end
end
