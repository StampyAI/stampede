defmodule SiteConfig do
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S
  require S

  @yaml_opts [:plain_as_atom]

  @type! service :: atom()
  @type! server_id :: S.server_id()
  @type! channel_id :: S.channel_id()
  @type! schema :: keyword() | struct()
  @type! t :: map(atom(), any())

  @schema_base [
    service: [
      required: true,
      type: :atom,
      doc: "Which service does your server reside on? Affects what config options are valid."
    ],
    server_id: [
      required: true,
      type: :any,
      doc: "Discord Guild ID, Slack group, etc"
    ],
    error_channel_id: [
      required: true,
      type: :any,
      doc:
        "What channel should debugging messages be posted on? Messages may have private information."
    ],
    prefix: [
      default: "!",
      type: S.ntc(Regex.t() | String.t()),
      doc: "What prefix should users put on messages to have them responded to?"
    ],
    plugs: [
      default: :all,
      type: {:custom, __MODULE__, :real_plugins, []},
      doc: "Which plugins will be asked for responses."
    ]
  ]
  @doc """
  A basic Cfg schema, extended by the specific service it's written for.

  #{NimbleOptions.docs(NimbleOptions.new!(@schema_base))}
  """
  def schema_base(), do: @schema_base

  def merge_custom_schema(overrides, base_schema \\ schema_base()) do
    Keyword.merge(base_schema, overrides, fn
      _key, base_settings, new_settings ->
        case Keyword.get(base_settings, :doc, false) do
          false -> new_settings
          doc -> Keyword.put_new(new_settings, :doc, doc)
        end
    end)
  end

  def schema(:dummy),
    do: Service.Dummy.site_config_schema()

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
      {:error,
       "Some plugins not found.\nFound: #{inspect(existing)}\nConfigured: #{inspect(plugs)}"}
    end
  end

  @doc "take input config as keywords, transform as necessary, validate, and return as map"
  @spec! validate!(keyword(), nil | schema(), [] | list((keyword(), schema() -> keyword()))) ::
           SiteConfig.t()
  def validate!(kwlist, schema \\ nil, additional_transforms \\ []) do
    schema = schema || Keyword.fetch!(kwlist, :service) |> schema()

    transforms = [
      &concat_plugs/2,
      &make_regex/2,
      fn kwlist, _ ->
        Keyword.update!(kwlist, :service, &S.service_atom_to_name(&1))
      end
    ]

    Enum.reduce(transforms ++ additional_transforms, kwlist, fn f, acc ->
      f.(acc, schema)
    end)
    |> NimbleOptions.validate!(schema)
    |> Map.new()
  end

  def concat_plugs(kwlist, _schema) do
    if is_list(Keyword.get(kwlist, :plugs)) do
      Keyword.update!(kwlist, :plugs, fn plugs ->
        case plugs do
          :all ->
            :all

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

  @spec! load_from_string(String.t()) :: SiteConfig.t()
  def load_from_string(yml) do
    case :fast_yaml.decode(yml, @yaml_opts) do
      {:error, reason} ->
        raise("bad yaml from string\n#{reason}")

      {:ok, [result]} ->
        validate!(result)
    end
  end

  @spec! load(String.t()) :: SiteConfig.t()
  def load(path) do
    str = File.read!(path)
    load_from_string(str)
  end

  @spec! load_all(String.t()) :: cfg_list()
  def load_all(dir) do
    target_dir = dir
    # case Application.fetch_env!(:stampede, :compile_env) do
    #  :prod ->
    #    dir

    #  other when is_atom(other) ->
    #    dir <> "_" <> Atom.to_string(other)
    # end

    Path.wildcard(target_dir <> "/*")
    |> Enum.map(fn path ->
      site_name = String.to_atom(Path.basename(path, ".yml"))
      config = load(path)
      {site_name, config}
    end)
    |> Enum.into(%{})
  end
end
