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
      type: :atom,
      doc: "Which service does your server reside on? Affects what config options are valid."
    ],
    server_id: [
      required: true,
      type: :any,
      doc: "Dicord Guild ID, Slack group, etc"
    ],
    error_channel_id: [
      required: true,
      type: :any,
      doc: "What channel should debugging messages be posted on? THIS SHOULD BE PRIVATE."
    ],
    prefix: [
      default: "!",
      type: S.ntc(Regex.t() | String.t()),
      doc: "What prefix should users put on messages to have them responded to?"
    ],
    plugs: [
      default: :all,
      type: {:custom, __MODULE__, :real_plugins, []},
      doc: "Which plugins will be asked for responses"
    ],
    app_id: [
      default: Stampede,
      type: :atom,
      doc: """
      Testing and debugging only. Used for redirecting queries to shared
      resources, such as Stampede.Registry, Stampede.QuickTaskSupers, etc. by
      renaming "Stampede" to something else. This isn't exactly a "site" config
      but it saves needing a lot of extra function args all over the place.
      """
    ]
  ]
  @type! site_name :: atom()
  @type! cfg_list :: map(site_name(), SiteConfig.t())

  def real_plugins(:all), do: {:ok, :all}
  def real_plugins(:none), do: {:ok, :none}
  def real_plugins(plugs) when not is_struct(plugs, MapSet), do: {:error, "This is not a MapSet"}
  def real_plugins(plugs) when is_struct(plugs, MapSet) do
    existing = Plugin.ls(plugs)
    if MapSet.equal?(existing, plugs) do
      {:ok, plugs}
    else
      {:error, "Some plugins not found.\nFound: #{inspect(existing)}\nConfigured: #{inspect(plugs)}"}
    end
  end
  @doc "take input config as keywords, transform as necessary, validate, and return as map"
  @spec! validate!(keyword(), keyword() | struct(),
    [] | list(TypeCheck.Builtin.function(keyword()))) :: SiteConfig.t()
  def validate!(kwlist, schema, additional_transforms \\ []) do
    transforms = [
      &concat_plugs/2,
      &make_regex/2,
      &atomize_app_id/2
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
  def atomize_app_id(kwlist, _schema) do
    if Keyword.has_key?(kwlist, :app_id) do
      Keyword.update!(kwlist, :app_id, fn 
        s when is_binary(s) -> 
          Module.concat([s])
        a when is_atom(a) -> 
          a
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
