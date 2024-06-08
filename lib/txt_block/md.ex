defmodule TxtBlock.Md do
  @moduledoc false
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck
  alias Stampede, as: S

  @spec! format(TxtBlock.t(), TxtBlock.type()) :: S.str_list()
  def format(input, type)

  def format(txt, {:indent, n}),
    do: TxtBlock.plain_indent_io(txt, n)

  def format(txt, :quote_block) do
    if S.enable_typechecking?(), do: TypeCheck.conforms!(txt, S.str_list())

    TxtBlock.plain_indent_io(txt, "> ")
  end

  def format(txt, :source_block) do
    if S.enable_typechecking?(), do: TypeCheck.conforms!(txt, S.str_list())

    [
      "```\n",
      txt,
      "```\n"
    ]
  end

  def format(txt, :source) do
    if S.enable_typechecking?(), do: TypeCheck.conforms!(txt, S.str_list())

    ["`", txt, "`"]
  end

  def format(items, {:list, :dotted}) when is_list(items) do
    Enum.flat_map(items, fn blk ->
      ["- ", blk, "\n"]
    end)
  end

  def format(items, {:list, :numbered}) when is_list(items) do
    Enum.map_reduce(items, 0, fn blk, i ->
      j = i + 1

      {
        [j |> Integer.to_string(), ". ", blk, "\n"],
        j
      }
    end)
    |> elem(0)
  end

  def format(txt, :italics) do
    [
      "*",
      txt,
      "*"
    ]
  end

  def format(txt, :bold) do
    [
      "**",
      txt,
      "**"
    ]
  end
end
