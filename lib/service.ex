defmodule Service do
  use TypeCheck
  alias Stampede, as: S

  @callback site_config_schema() :: NimbleOptions.t()
  @callback into_msg(service_message :: any()) :: %Stampede.Msg{}
  @callback dm?(service_message :: any()) :: boolean()
  @callback author_privileged?(server_id :: any(), author_id :: any()) :: boolean()
  @callback bot_id?(user_id :: any()) :: boolean()
  @callback at_bot?(
              cfg :: SiteConfig.t(),
              message :: S.Msg.t()
            ) :: boolean()
  @callback send_msg(destination :: any(), text :: binary(), opts :: keyword()) :: any()
  @callback log_plugin_error(
              cfg :: SiteConfig.t(),
              message :: S.Msg.t(),
              error_info :: PluginCrashInfo.t()
            ) :: {:ok, formatted :: TxtBlock.t()}
  @callback log_serious_error(
              log_msg ::
                {level :: Stampede.log_level(), _gl :: any(),
                 {module :: Logger, message :: any(), _timestamp :: any(), _metadata :: any()}}
            ) :: :ok
  @callback reload_configs() :: :ok | {:error, any()}

  @callback txt_format(blk :: TxtBlock.t(), type :: TxtBlock.type()) :: S.str_list()
  @callback format_plugin_fail(
              cfg :: SiteConfig.t(),
              msg :: S.Msg.t(),
              error_info :: PluginCrashInfo.t()
            ) :: TxtBlock.t()

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
    |> apply_service_function(func_name, args)
  end

  def apply_service_function(service_name, func_name, args) when is_atom(service_name) do
    apply(service_name, func_name, args)
  end

  # TODO: move into service-generic Stampede.Logger
  def txt_format(blk, type, :logger),
    do: TxtBlock.Md.format(blk, type)

  def txt_format(blk, type, cfg_or_service),
    do: apply_service_function(cfg_or_service, :txt_format, [blk, type])
end
