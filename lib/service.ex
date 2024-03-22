defmodule Service do
  use TypeCheck
  alias Stampede, as: S

  @doc "return description of valid site config options"
  @callback site_config_schema() :: NimbleOptions.t()
  @doc "Put the service's internal message representation into a generic Msg"
  @callback into_msg(service_message :: any()) :: %Stampede.Msg{}
  @doc "Is this service message a DM?"
  @callback dm?(service_message :: any()) :: boolean()
  @doc "Is this author considered privileged in this context?"
  @callback author_privileged?(server_id :: any(), author_id :: any()) :: boolean()
  @doc "Is this user the bot itself?"
  @callback bot_id?(user_id :: any()) :: boolean()
  @doc "Is this message targeted at the bot in a service-specific way?"
  @callback at_bot?(
              cfg :: SiteConfig.t(),
              message :: S.Msg.t()
            ) :: boolean()
  @doc "Send a message on this service"
  @callback send_msg(destination :: any(), text :: TxtBlock.t(), opts :: keyword()) :: any()
  @doc "Log a safely caught plugin error. Often called from Plugin.get_top_response()"
  @callback log_plugin_error(
              cfg :: SiteConfig.t(),
              message :: S.Msg.t(),
              error_info :: PluginCrashInfo.t()
            ) :: {:ok, formatted :: TxtBlock.t()}
  @doc "Report an uncaught error from the Erlang logger. Could have sensitive info for the bot host."
  @callback log_serious_error(
              log_msg ::
                {level :: Stampede.log_level(), _gl :: any(),
                 {module :: Logger, message :: any(), _timestamp :: any(), _metadata :: any()}}
            ) :: :ok
  @doc "Site configs have been updated and the service should be updated"
  @callback reload_configs() :: :ok | {:error, any()}

  @doc "Specifies how this service formats TxtBlocks into messages. Non-recursive"
  @callback txt_format(blk :: TxtBlock.t(), type :: TxtBlock.type()) :: S.str_list()
  @doc "How this service wants plugin errors to be displayed."
  @callback format_plugin_fail(
              cfg :: SiteConfig.t(),
              msg :: S.Msg.t(),
              error_info :: PluginCrashInfo.t()
            ) :: TxtBlock.t()

  @doc "Called by Stampede.Application supervisor"
  @callback start_link(Keyword.t()) :: :ignore | {:error, any} | {:ok, pid}

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour unquote(__MODULE__)

      # in order to use the default schema in doc strings, use this attribute, as the function will not be found when the compiler is compiling the docstring.
      # For example:
      #
      #   @moduledoc """
      #   Config options:
      #   #{NimbleOptions.docs(@site_config_schema)}
      #   """
      @site_config_schema SiteConfig.schema_base() |> NimbleOptions.new!()

      @impl unquote(__MODULE__)
      def site_config_schema(), do: @site_config_schema

      defoverridable site_config_schema: 0
    end
  end

  # service polymorphism basically
  @spec! apply_service_function(SiteConfig.t() | atom(), atom(), list()) :: any()
  def apply_service_function(cfg, func_name, args)
      when is_map(cfg) do
    cfg
    |> SiteConfig.fetch!(:service)
    |> __MODULE__.apply_service_function(func_name, args)
  end

  def apply_service_function(service_name, func_name, args) when is_atom(service_name) do
    apply(service_name, func_name, args)
  end

  # Some common functions make more sense being abbreviated here

  # TODO: move this into service-generic Stampede.Logger
  def txt_format(blk, type, :logger),
    do: TxtBlock.Md.format(blk, type)

  def txt_format(blk, type, cfg_or_service),
    do: __MODULE__.apply_service_function(cfg_or_service, :txt_format, [blk, type])
end
