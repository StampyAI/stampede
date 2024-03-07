defmodule TxtBlock do
  @doc """
  Storage for text to be formatted differently according to context, i.e. posting to different services. str_list-friendly.

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
  @type! t :: [] | nonempty_list(lazy(t())) | String.t() | lazy(block)

  @spec! to_str_list(t(), module()) :: S.str_list()
  def to_str_list(item, service_name) when not is_list(item) do
    case item do
      txt when is_binary(txt) ->
        txt

      {type, blk} ->
        to_str_list(blk, service_name)
        |> Service.txt_format(type, service_name)
    end
  end

  def to_str_list(blueprint, service_name) when is_list(blueprint) do
    # TODO: check performance of flattened vs non-flattened lists
    List.foldl(blueprint, [], fn
      [], acc ->
        acc

      item, acc ->
        to_str_list(item, service_name)
        |> case do
          [] ->
            acc

          other ->
            acc ++ List.wrap(other)
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

  @spec! plain_indent_io(S.str_list(), String.t() | non_neg_integer()) :: S.str_list()
  def plain_indent_io(str, n) when is_integer(n),
    do: str |> plain_indent_io(String.duplicate(" ", n))

  def plain_indent_io(str, prefix) when is_binary(prefix) do
    IO.iodata_to_binary(str)
    |> String.split("\n")
    |> Enum.flat_map(&[prefix, &1, "\n"])
  end
end

defmodule TxtBlock.Debugging do
  use TypeCheck

  @spec! all_formats_example() :: TxtBlock.t()
  def all_formats_example() do
    [
      "Testing formats.\n\n",
      "Quoted\n",
      {:quote_block, "Quoted line 1\nQuoted line 2 with newline\n"},
      {:quote_block, "Quoted line 1\nQuoted line 2 without newline"},
      {:source_block, "source(1)\nsource(2, \"with_newline\")\n"},
      {:source_block, "source(1)\nsource(2, \"without_newline\")"},
      ["Inline source quote ", {:source, "foobar"}, "\n"],
      {{:indent, "><> "}, ["school\n", "\nof", "\nfishies"]},
      "\n",
      "Dotted list",
      {{:list, :dotted}, ["Item 1", "Item 2 with newline\n", "Item 3"]},
      "Numbered list",
      {{:list, :numbered}, ["Item 1", "Item 2 with newline", "Item 3"]}
    ]
  end
end
