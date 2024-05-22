defmodule Stampede.Msg do
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    id: _ :: S.msg_id(),
    body: _ :: String.t(),
    channel_id: _ :: S.channel_id(),
    author_id: _ :: S.user_id(),
    server_id: _ :: S.server_id(),
    service: _ :: module(),
    referenced_msg_id: nil :: nil | S.msg_id(),
    # late resolved context
    at_bot?: :unset_key :: :unset_key | boolean(),
    dm?: :unset_key :: :unset_key | boolean(),
    prefix: :unset_key :: :unset_key | false | String.t()
  )

  defmacro new(keys) do
    quote do
      struct!(
        unquote(__MODULE__),
        unquote(keys)
        |> Keyword.put_new(:service, __MODULE__)
      )
    end
  end

  # late resolved context
  @spec! add_context(%__MODULE__{}, SiteConfig.t()) :: %__MODULE__{}
  def add_context(msg, cfg) do
    for unset_key <- [
          :at_bot?,
          :dm?,
          :prefix
        ] do
      unless Map.fetch!(msg, unset_key) == :unset_key do
        raise "Expected #{S.pp(unset_key)} to be :unset_key, was #{S.pp(msg.unset_key)}"
      end
    end

    {prefix, cleaned} = S.split_prefix(msg.body, cfg.prefix)
    # coerce to boolean
    at_bot = Service.apply_service_function(cfg, :at_bot?, [cfg, msg])
    dm = Service.apply_service_function(cfg, :dm?, [msg])

    msg
    |> Map.merge(%{
      at_bot?: at_bot,
      dm?: dm,
      prefix: prefix
    })
    |> Map.update!(:body, fn
      current_text ->
        (prefix && cleaned) || current_text
    end)
  end
end
