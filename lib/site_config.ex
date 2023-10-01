defmodule SiteConfig do
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S
  require S

  @yaml_opts [:plain_as_atom]

  @type! service :: atom()
  @type! server_id :: S.server_id()
  @type! channel_id :: S.channel_id()
  @type! t :: map(atom(), any())
  def schema_base(), do: [
      service: [
        required: true,
        type: :atom
      ],
      server_id: [
        required: true,
        type: :any
      ],
      error_channel_id: [
        required: true,
        type: :any
      ],
      prefix: [
        default: "!",
        type: S.ntc(Regex.t() | String.t()),
      ],
      plugs: [
        default: :all,
        type: S.ntc(%MapSet{} | :all | MapSet.t(atom()))
      ]
    ]
  @type! site_name :: atom()
  @type! cfg_list :: map(site_name(), SiteConfig.t())

  @doc "take input config as keywords, transform as necessary, validate, and return as map"
  @spec! validate(keyword(), keyword(), [] | list(TypeCheck.Builtin.function(keyword()))) :: SiteConfig.t()
  def validate(kwlist, schema, additional_transforms \\ []) do
    transforms = [
      &concat_plugs/2,
      &make_regex/2
    ]
    Enum.reduce(transforms ++ additional_transforms, kwlist,
      fn f, acc ->
        f.(acc, schema)
    end)
    |> NimbleOptions.validate!(schema)
    |> Map.new()
  end
  def concat_plugs(kwlist, _schema) do
    if is_list(Keyword.get(kwlist, :plugs)) do
      Keyword.update!(kwlist, :plugs, fn plugs -> 
        case plugs do
          :all -> :all
          ll when is_list(ll) -> 
            Enum.map(ll, &Module.safe_concat(Plugin, &1))
            |> MapSet.new()
        end
      end)
    else
      kwlist
    end
  end
  def make_regex(kwlist, _schema) do
    if Keyword.has_key?(kwlist, :prefix) do
      Keyword.update!(kwlist, :prefix, fn prefix -> 
        if String.starts_with?(prefix, "~r") do
          Regex.compile!(prefix)
        else
          prefix
        end
      end)
    else
      kwlist
    end
  end

  @spec! load_from_string(String.t()) :: keyword()
  def load_from_string(yml) do
    case :fast_yaml.decode(yml, @yaml_opts) do
      {:ok, [result]} -> result
      {:error, reason} -> raise("bad yaml from string\n#{reason}")
    end
  end
  @spec! load(String.t()) :: keyword()
  def load(path) do
    str = File.read!(path)
    load_from_string(str)
  end
  @spec! load_all(String.t()) :: cfg_list()
  def load_all(dir) do
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
