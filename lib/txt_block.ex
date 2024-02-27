defmodule TxtBlock do
  @doc """
  Storage for text to be formatted differently according to context, i.e. posting to different services. iolist-friendly.

  Section types with their markdown equivalents:
  - quote_block (greater-than signs '>')
  - source_block (triple backticks)
  - source (single backticks)
  """

  use TypeCheck
  alias Stampede, as: S

  @type! modes :: :quote_block | :source_block | :source | {:indent, pos_integer() | String.t()}
  @type! t :: [] | maybe_improper_list(lazy(t()), lazy(t())) | String.t() | {modes(), lazy(t())}
  @type! t_formatted ::
           [] | String.t() | maybe_improper_list(lazy(t_formatted()), lazy(t_formatted()))

  @spec! to_iolist(t(), module()) :: t_formatted()
  def to_iolist(item, service_name) when not is_list(item) do
    case item do
      txt when is_binary(txt) ->
        txt

      {:source_block, blk} ->
        to_iolist(blk, service_name)
        |> Service.txt_source_block(service_name)

      {:source, blk} ->
        to_iolist(blk, service_name)
        |> Service.txt_source(service_name)

      {:quote_block, blk} ->
        to_iolist(blk, service_name)
        |> Service.txt_quote_block(service_name)

      {{:indent, n}, blk} ->
        to_iolist(blk, service_name)
        |> Stampede.txt_indent_io(n)
    end
  end

  def to_iolist(blueprint, service_name) when is_list(blueprint) do
    List.foldr(blueprint, [], fn
      [], acc ->
        acc
        |> IO.inspect(pretty: true)

      item, acc ->
        to_iolist(item, service_name)
        |> case do
          [] ->
            acc

          [singleton] ->
            [singleton | acc]

          other ->
            [other | acc]
        end
        |> IO.inspect(pretty: true)
    end)
    |> case do
      [] ->
        []

      [singleton] ->
        singleton

      other ->
        other
    end
  end
end
