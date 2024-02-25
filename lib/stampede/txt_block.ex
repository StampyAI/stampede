defmodule Stampede.TxtBlock do
  @doc """
  Storage for text to be formatted differently according to context, i.e. posting to different services. iolist-friendly.

  Section types with their markdown equivalents:
  - quote_block (greater-than signs '>')
  - source_block (triple backticks)
  - source (single backticks)
  """

  use TypeCheck

  @type! modes :: :quote_block | :source_block | :source | {:indent, pos_integer()}
  @type! t :: String.t() | list(String.t() | {modes(), String.t()})

  def to_iolist(item, service_name) when not is_list(item) do
    case item do
      [] ->
        []

      ls when is_list(ls) ->
        to_iolist(ls, service_name)

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
    blueprint
    |> Enum.map(&to_iolist(&1, service_name))
    |> case do
      [item] ->
        item

      other ->
        other
    end
  end
end
