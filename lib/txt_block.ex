defmodule TxtBlock do
  @compile [:bin_opt_info, :recv_opt_info]
  @moduledoc """
  Symbolic storage for text to be formatted differently according to context, i.e. posting to different services. iolist-friendly (except for improper lists).

  Section types with their markdown equivalents as examples, see also TxtBlock.Debugging.all_formats_example()
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
           | :italics
           | :bold
  @type! t :: [] | nonempty_list(lazy(t())) | String.t() | lazy(block)

  @spec! to_binary(t(), module()) :: String.t()
  def to_binary(blk, service_name) do
    to_str_list(blk, service_name)
    |> IO.iodata_to_binary()
  end

  defguard is_list_sensitive(type)
           when is_tuple(type) and tuple_size(type) == 2 and elem(type, 0) == :list

  @spec! to_str_list(t(), module()) :: S.str_list()
  def to_str_list(txt, _service_name)
      when is_binary(txt),
      do: txt

  def to_str_list({type, blk}, service_name)
      when is_list_sensitive(type) do
    Enum.map(blk, &to_str_list(&1, service_name))
    |> Service.txt_format(type, service_name)
  end

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

  @spec! plain_indent_io(S.str_list(), String.t() | non_neg_integer(), nil | {:bm, any()}) ::
           S.str_list()
  def plain_indent_io(str, n, bp \\ nil)

  def plain_indent_io(str, n, bp) when is_integer(n),
    do: str |> plain_indent_io(String.duplicate(" ", n), bp)

  def plain_indent_io(str, prefix, bp) when is_binary(prefix) do
    IO.iodata_to_binary(str)
    # TODO: this is being recompiled every time. figure out how to
    # precompile binary patterns without needing application state
    |> String.split(bp || bp_newline(), trim: true)
    |> Enum.flat_map(&[prefix, &1, "\n"])
  end

  def bp_newline(), do: :binary.compile_pattern("\n")
end

defmodule TxtBlock.Debugging do
  @moduledoc false
  use TypeCheck

  @spec! all_formats_example() :: TxtBlock.t()
  def all_formats_example() do
    [
      "Testing formats.\n\n",
      {:italics, "Italicized"},
      " and ",
      {:bold, "bolded"},
      "\n\n",
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
      {{:list, :numbered}, ["Item 1", {:italics, "Nested Italics Item 2"}, "Item 3"]}
    ]
  end
end
