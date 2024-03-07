defmodule TxtBlock.Md do
  use TypeCheck
  alias Stampede, as: S

  @spec! format(TxtBlock.t(), TxtBlock.type()) :: S.str_list()
  def format(input, type)

  def format(txt, {:indent, n}),
    do: TxtBlock.plain_indent_io(txt, n)

  def format(txt, :quote_block) do
    TypeCheck.conforms!(txt, S.str_list())

    TxtBlock.plain_indent_io(txt, "> ")
  end

  def format(txt, :source_block) do
    TypeCheck.conforms!(txt, S.str_list())

    [
      "```\n",
      txt,
      "\n```\n"
    ]
  end

  def format(txt, :source) do
    TypeCheck.conforms!(txt, S.str_list())

    ["`", txt, "`"]
  end

  def format(items, {:list, :dotted}) when is_list(items) do
    Enum.map(items, fn blk ->
      ["- ", blk, "\n"]
    end)
  end

  def format(items, {:list, :numbered}) when is_list(items) do
    Enum.reduce(items, {[], 0}, fn blk, {ls, i} ->
      j = i + 1

      {
        [j |> Integer.to_string(), ". ", blk, "\n" | ls],
        j
      }
    end)
    |> elem(0)
  end

  defmodule Debugging do
    def all_formats_processed() do
      """
      Testing formats.

      Quoted
      > Quoted line 1
      > Quoted line 2 with newline

      > Quoted line 1
      > Quoted line 2 without newline
      ```
      source(1)
      source(2, "with_newline")
      ```
      ```
      source(1)
      source(2, "without_newline")
      ```
      Inline source quote `foobar`
      ><> school
      ><> of
      ><> fishies

      Dotted list
      - Item 1
      - Item 2
      - Improper list item 3
      Numbered list
      1. Item 1
      2. Item 2
      3. Improper list item 3
      Improper end
      """
    end
  end
end
