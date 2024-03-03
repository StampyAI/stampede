defmodule TxtBlock.Md do
  use TypeCheck
  alias Stampede, as: S

  @spec! format(TxtBlock.t(), TxtBlock.type()) :: S.io_list()
  def format(input, type)

  def format(txt, {:indent, n}),
    do: TxtBlock.plain_indent_io(txt, n)

  def format(txt, :quote_block) do
    TypeCheck.conforms!(txt, S.io_list())

    TxtBlock.plain_indent_io(txt, "> ")
  end

  def format(txt, :source_block) do
    TypeCheck.conforms!(txt, S.io_list())

    [
      "```\n",
      txt,
      "\n```\n"
    ]
  end

  def format(txt, :source) do
    TypeCheck.conforms!(txt, S.io_list())

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
end
