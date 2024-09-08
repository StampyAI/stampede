defmodule SiteConfig do
  @compile [:bin_opt_info, :recv_opt_info]
  @moduledoc """
  This module defines how per-site configurations are validated and represented.

  A configuration usually starts as a YAML file on-disk. It is then:
  - read into an Erlang term
  - validated with NimbleOptions (simultaneously handling defaults and type-checking)
  - some transformations are done; for example, turning atoms referring to services and plugins into their proper names ("discord" into Elixir.Services.Discord, "why" into Elixir.Plugins.Why).
  - turned into a SiteConfig struct (internally a map)
  - Given to Stampede.CfgTable which handles storage of the configs and keeping services up-to-date.

  schema_base() defines a basic site config schema, which is extended by Services for their needs.
  """
  use TypeCheck
  use TypeCheck.Defstruct
  require Logger
  alias Stampede, as: S
  require S

  @yaml_opts [:plain_as_atom]

  @type! service :: atom()
  @type! server_id :: S.server_id()
  @type! channel_id :: S.channel_id()
  @type! schema :: keyword() | struct()
  @type! site_name :: atom()
  @typedoc "A nested collection of configs, organized by service, then server_id"
  @type! cfg_list :: map(service(), map(server_id(), SiteConfig.t()))
  @type! t :: map(atom(), any())

  @schema_base [
    service: [
      required: true,
      type: :atom,
      doc:
        "Which service does your server reside on? Affects what config options are valid. A basic atom which becomes the module name, i.e. :discord -> Services.Discord"
    ],
    server_id: [
      required: true,
      type: :any,
      doc: "Discord Guild ID, Slack group, etc. Name 'DM' for direct message handling"
    ],
    vip_ids: [
      default: MapSet.new(),
      type: :any,
      doc: "User IDs, who are trusted to not abuse the bot"
    ],
    error_channel_id: [
      required: true,
      type: :any,
      doc:
        "What channel should debugging messages be posted on? Messages may have private information."
    ],
    prefix: [
      default: "!",
      type: {:or, [:string, {:list, :string}]},
      doc: "What prefix should users put on messages to have them responded to?"
    ],
    plugs: [
      default: :all,
      type: {:custom, __MODULE__, :real_plugins, []},
      doc: "Which plugins will be asked for responses."
    ],
    dm_handler: [
      default: false,
      type: :boolean,
      doc: "Use this config for DMs received on this service. Only one config per service"
    ],
    bot_is_loud: [
      default: false,
      type: :boolean,
      doc: "Can this bot send messages when not explicitly tagged?"
    ],
    filename: [
      type: :string,
      required: false,
      doc: "File this config was loaded from"
    ]
  ]
  @mapset_keys [:vip_ids]
  @doc """
  A basic Cfg schema, to be extended by the specific service it's written for.

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

  def schema(atom),
    do: S.service_atom_to_name(atom).site_config_schema()

  def fetch!(cfg, key) when is_map_key(cfg, key), do: Map.fetch!(cfg, key)

  @doc "return all plugs that this site expects"
  def get_plugs(:all), do: Plugin.ls()

  def get_plugs(cfg) when not is_struct(cfg, MapSet),
    do: fetch!(cfg, :plugs) |> get_plugs()

  def get_plugs(plugs) do
    {:ok, plugs} = real_plugins(plugs)
    plugs
  end

  @doc "Verify that explicitly listed plugins actually exist"
  def real_plugins(:all), do: {:ok, :all}

  def real_plugins(plugs) when not is_struct(plugs, MapSet),
    do: raise("This is not a mapset: #{inspect(plugs)}")

  def real_plugins(plugs) when is_struct(plugs, MapSet) do
    if Plugin.loaded?(plugs) do
      {:ok, plugs}
    else
      raise "Some plugins not found.\nFound: #{inspect(Plugin.ls())}\nConfigured: #{inspect(plugs)}"
    end
  end

  @doc "take input config as keywords, transform as necessary, validate, and return as map"
  @spec! validate!(
           kwlist :: keyword(),
           schema :: nil | schema(),
           additional_transforms :: [] | list((keyword(), schema() -> keyword()))
         ) ::
           SiteConfig.t()
  def validate!(kwlist, schema \\ nil, additional_transforms \\ []) do
    schema = schema || Keyword.fetch!(kwlist, :service) |> schema()

    transforms = [
      &concat_plugs/2,
      make_mapsets(@mapset_keys),
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

  @spec! revalidate!(kwlist :: keyword() | map(), schema :: nil | schema()) :: SiteConfig.t()
  def revalidate!(cfg, schema) do
    cfg
    |> then(fn
      l when is_list(l) -> l
      m when is_map(m) -> Map.to_list(m)
    end)
    |> NimbleOptions.validate!(schema)
    |> Map.new()
  end

  @doc "Turn plug_name into Elixir.Plugins.PlugName"
  def concat_plugs(kwlist, _schema) do
    if is_list(Keyword.get(kwlist, :plugs)) do
      Keyword.update!(kwlist, :plugs, fn plugs ->
        case plugs do
          :all ->
            :all

          ll when is_list(ll) ->
            Enum.map(ll, fn name ->
              camel_name = name |> to_string() |> Macro.camelize()
              Module.safe_concat(Plugins, camel_name)
            end)
            |> MapSet.new()
        end
      end)
    else
      kwlist
    end
  end

  @doc "For the given keys, make a function that will replace the enumerables at those keys with MapSets"
  @spec! make_mapsets(list(atom()) | %MapSet{}) :: (keyword(), any() -> keyword())
  def make_mapsets(keys) do
    fn kwlist, _schema ->
      Enum.reduce(keys, kwlist, fn key, acc ->
        case Keyword.get(acc, key, false) do
          false ->
            acc

          enum when is_list(enum) or enum == [] ->
            Keyword.update!(acc, key, fn enum -> MapSet.new(enum) end)

          ms when is_struct(ms, MapSet) ->
            acc
        end
      end)
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
    File.read!(path)
    |> load_from_string()
  end

  @doc "Load all YML files in a directory and return a map of configs"
  @spec! load_all(String.t()) :: cfg_list()
  def load_all(dir) do
    target_dir = dir
    # IO.puts("target dir " <> dir) # DEBUG

    Path.wildcard(target_dir <> "/*")
    |> Enum.reduce(Map.new(), fn path, service_map ->
      site_name = Path.basename(path, ".yml")
      # IO.puts("add #{site_name} at #{path} to #{S.pp(service_map)}") # DEBUG
      config =
        load(path)
        |> Map.put(:filename, site_name)

      service = Map.fetch!(config, :service)
      server_id = Map.fetch!(config, :server_id)

      service_map
      |> Map.put_new(service, Map.new())
      |> Map.update!(service, fn
        server_map ->
          # IO.puts("add server #{server_id} to service #{service}") # DEBUG
          Map.put(server_map, server_id, config)
      end)
      |> make_configs_for_dm_handling()
    end)

    # Did you know that "default" in Map.update/4 isn't an input to the
    # function? It just skips the function and adds that default to the map.
    # I didn't know that. Now I do. :')
  end

  @spec! make_configs_for_dm_handling(cfg_list()) :: cfg_list()
  @doc """
  Create a config with key {:dm, service} which all DMs for a service will be handled under.
  If server_id is not "DM", it will be duplicated with one for the server and
  one for the DMs. This lets you use the same settings for a server and for DMs, when convenient.
  Collects all VIPs for that service and puts them in the DM config.
  """
  # TODO: make this happen across entire cfg table on every new config load. Maybe have a dedicated sanity-checking stage that can refuse bad configs.
  def make_configs_for_dm_handling(service_map) do
    Map.new(service_map, fn {service, site_map} ->
      dupe_checked =
        Enum.reduce(
          site_map,
          {Map.new(), MapSet.new(), MapSet.new()},
          # Accumulator keeps a map for the sites being processed, and two mapsets to check for duplicate keys
          fn {server_id, orig_cfg}, {site_acc, services_handled, service_vips} ->
            if not orig_cfg.dm_handler do
              {
                Map.put(site_acc, server_id, orig_cfg),
                services_handled,
                if vips = Map.get(orig_cfg, :vip_ids, false) do
                  MapSet.union(service_vips, vips)
                else
                  service_vips
                end
              }
            else
              if orig_cfg.service in services_handled do
                raise "duplicate dm_handler for service #{orig_cfg.service |> inspect()}"
              end

              dm_key = S.make_dm_tuple(orig_cfg.service)
              dm_cfg = Map.put(orig_cfg, :server_id, dm_key)

              # config is for DM handling exclusively
              new_site_acc =
                if server_id != "DM" do
                  Map.put(site_acc, server_id, orig_cfg)
                else
                  site_acc
                end
                |> Map.put(dm_key, dm_cfg)

              {
                new_site_acc,
                services_handled |> MapSet.put(orig_cfg.service),
                if vips = Map.get(orig_cfg, :vip_ids, false) do
                  MapSet.union(service_vips, vips)
                else
                  service_vips
                end
              }
            end
          end
        )
        |> elem(0)

      {service, dupe_checked}
    end)
  end

  def trim_plugin_name(plug) do
    plug
    |> Atom.to_string()
    |> S.split_prefix("Elixir.Plugins.")
    |> then(fn {status, string} ->
      if status != false, do: string, else: raise("should have trimmed " <> Atom.to_string(plug))
    end)
  end

  def trim_plugin_names(:all),
    do: Plugin.ls() |> trim_plugin_names()

  def trim_plugin_names(plist),
    do: Enum.map(plist, &trim_plugin_name/1)

  def example_prefix(cfg) do
    case cfg.prefix do
      [car | _cdr] ->
        car

      otherwise ->
        otherwise
    end
  end

  def maybe_sort_prefixes(cfg, _schema) do
    # check and warn for conflicting prefixes
    cfg[:prefix]
    |> case do
      nil ->
        cfg

      singular when not is_list(singular) ->
        cfg

      ps when is_list(ps) ->
        case check_prefixes_for_conflicts(ps) do
          :no_conflict ->
            cfg

          {:conflict, mangled_prefix, prefix_responsible, how_it_was_mangled} ->
            sorted = S.sort_rev_str_len(ps)

            Logger.warning(fn ->
              """
              Prefix "#{mangled_prefix}" was interrupted by prefix "#{prefix_responsible}". What this means:
              - sent command: `#{mangled_prefix} hello`
              - intended command: `hello`
              - interpreted command: `#{how_it_was_mangled}`

              This could be fixed by putting `#{prefix_responsible}` after `#{mangled_prefix}` in the list.

              We sorted the list for you:
              #{ps |> S.pp()} |> #{sorted |> S.pp()}
              """
            end)

            Keyword.put(cfg, :prefix, sorted)
        end
    end
  end

  @spec! check_prefixes_for_conflicts(nonempty_list(binary())) ::
           :no_conflict
           | {:conflict, mangled_prefix :: binary(), prefix_responsible :: binary(),
              how_it_was_mangled :: binary()}
  def check_prefixes_for_conflicts([_h | []]), do: :no_conflict

  def check_prefixes_for_conflicts([prefix_that_interrupts | latter_prefixes]) do
    Enum.find_value(latter_prefixes, fn
      prefix_in_danger ->
        {false_or_prefix, mangled} = S.split_prefix(prefix_in_danger, prefix_that_interrupts)

        if false_or_prefix do
          {:conflict, prefix_in_danger, prefix_that_interrupts, mangled}
        else
          nil
        end
    end)
    |> case do
      nil ->
        check_prefixes_for_conflicts(latter_prefixes)

      otherwise ->
        otherwise
    end
  end
end
