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
  def to_str_list(txt, service_name)
      when is_binary(txt),
      do: txt

  def to_str_list({type, blk}, service_name) do
    to_str_list(blk, service_name)
    |> Service.txt_format(type, service_name)
  end

  def to_str_list(blk, service_name) when is_list(blk) do
    # TODO: check performance of flattened vs non-flattened lists
    List.foldl(blk, [], fn
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
    |> String.split("\n", trim: true)
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
      {:quote_block, "Quoted line 1\nQuoted line 2\n"},
      "\n",
      {:source_block, "source(1)\nsource(2)\n"},
      "\n",
      ["Inline source quote ", {:source, "foobar"}, "\n"],
      "\n",
      {{:indent, "><> "}, ["school\n", "of\n", "fishies\n"]},
      "\n",
      "Dotted list\n",
      {{:list, :dotted}, ["Item 1", "Item 2", "Item 3"]},
      "\n",
      "Numbered list\n",
      {{:list, :numbered}, ["Item 1", "Item 2", "Item 3"]}
    ]
  end
end
