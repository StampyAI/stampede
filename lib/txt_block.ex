defmodule TxtBlock do
  @doc """
  Storage for text to be formatted differently according to context, i.e. posting to different services. iolist-friendly.

  Section types with their markdown equivalents:
  - quote_block (greater-than signs '>')
  - source_block (triple backticks)
  - source (single backticks)
  - list, dotted (list starting with '-')
  - list, numbered (list starting with numbers)
  """

  use TypeCheck
  alias Stampede, as: S

  @type! block :: {type(), lazy(t())}
  @type! type ::
           :quote_block
           | :source_block
           | :source
           | {:indent, pos_integer() | String.t()}
           | {:list, :dotted | :numbered}
  @type! t :: [] | maybe_improper_list(lazy(t()), lazy(t())) | String.t() | lazy(block)

  @spec! to_iolist(t(), module()) :: S.io_list()
  def to_iolist(item, service_name) when not is_list(item) do
    case item do
      txt when is_binary(txt) ->
        txt

      {type, blk} ->
        to_iolist(blk, service_name)
        |> Service.txt_format(type, service_name)
    end
  end

  def to_iolist(blueprint, service_name) when is_list(blueprint) do
    S.foldr_improper(blueprint, [], fn
      [], acc ->
        acc

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

  @spec! plain_indent_io(S.io_list(), String.t() | non_neg_integer()) :: S.io_list()
  def plain_indent_io(str, n) when is_integer(n),
    do: str |> plain_indent_io(String.duplicate(" ", n))

  def plain_indent_io(str, prefix) when is_binary(prefix) do
    IO.iodata_to_binary(str)
    |> String.split("\n")
    |> Enum.map(&[prefix, &1, "\n"])
  end
end

defmodule TxtBlock.Debugging do
  use TypeCheck

  @spec! all_formats_example() :: TxtBlock.t()
  def all_formats_example() do
    [
      "Testing formats.\n",
      "Quoted\n",
      {:quote_block, "Quoted line 1\nQuoted line 2\nQuoted line 3\n"},
      {:source_block, "source(1)\nsource(2)\nsource(3)\n"},
      ["Inline source quote ", {:source, "foobar"}, "\n"],
      {{:indent, "><> "}, ["school\n", "\nof", "\nfishies"]},
      "\n",
      "Dotted list",
      {{:list, :dotted}, ["Item 1", "Item 2", ["Improper list item " | "3"]]},
      "Numbered list",
      {{:list, :numbered}, ["Item 1", "Item 2", ["Improper list item " | "3"]]}
      | "Improper end"
    ]
  end
end
