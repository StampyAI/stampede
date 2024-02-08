defmodule Service do
  use TypeCheck

  @callback site_config_schema() :: NimbleOptions.t()
  @callback into_msg(service_message :: term()) :: %Stampede.Msg{}
  @callback send_msg(destination :: term(), text :: binary(), opts :: keyword()) :: term()
  @callback log_plugin_error(cfg :: struct(), log :: binary()) :: :ok
  @callback log_serious_error(
              log_msg ::
                {level :: Stampede.log_level(), _gl :: term(),
                 {module :: Logger, message :: term(), _timestamp :: term(), _metadata :: term()}}
            ) :: :ok
  @callback reload_configs() :: :ok | {:error, any()}
  @callback author_is_privileged(server_id :: any(), author_id :: any()) :: boolean()

  @callback txt_source_block(txt :: binary()) :: binary()
  @callback txt_quote_block(txt :: binary()) :: binary()

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
  @spec! apply_service_function(SiteConfig.t(), atom(), list()) :: any()
  def apply_service_function(cfg, func_name, args)
      when is_atom(func_name) and is_list(args) do
    SiteConfig.fetch!(cfg, :service)
    |> apply(func_name, args)
  end

  def txt_source_block(cfg, text),
    do: apply_service_function(cfg, :txt_source_block, [text])
end
