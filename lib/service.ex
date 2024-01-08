defmodule Service do
  use TypeCheck

  @callback send_msg(destination :: term(), text :: binary(), opts :: keyword()) :: term()
  @callback log_plugin_error(cfg :: struct(), log :: binary()) :: :ok
  @callback start_link(Keyword.t()) :: :ignore | {:error, any} | {:ok, pid}
  @callback into_msg(service_message :: term()) :: %Stampede.Msg{}
  @callback log_serious_error(
              log_msg ::
                {level :: Stampede.log_level(), _gl :: term(),
                 {module :: Logger, message :: term(), _timestamp :: term(), _metadata :: term()}}
            ) :: :ok

  @callback txt_source_block(txt :: binary()) :: binary()

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour unquote(__MODULE__)
    end
  end

  def apply_service_function(cfg, func_name, args)
      when is_atom(func_name) and is_list(args) do
    SiteConfig.fetch!(cfg, :service)
    |> apply(:txt_source_block, args)
  end

  def txt_source_block(cfg, text),
    do: apply_service_function(cfg, :txt_source_block, [text])
end
