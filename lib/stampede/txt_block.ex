defmodule Stampede.TxtBlock do
  @doc """
  Storage for text to be formatted differently according to context. iolist-friendly.

  Section types with their markdown equivalents:
  - quote_block (greater-than signs '>')
  - source_block (triple backticks)
  - source (single backticks)
  """

  use TypeCheck

  @type! section_types :: :quote_block | :source_block | :source | {:indent, non_neg_integer()}
  @type! t :: String.t() | list(String.t() | {section_types(), String.t()})

  def to_iolist(blueprint, service) do
    blueprint
    |> Enum.map(fn
      ls when is_list(ls) ->
        to_iolist(ls, service)

      txt when is_binary(txt) ->
        txt

      {:quote_block, blk} ->
        Service.apply_service_function(service, :io_quote_block, [blk])
    end)
  end
end
