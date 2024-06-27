alias Stampede, as: S
require Stampede.Events.MsgReceived
require Aja

defmodule T do
  require Plugin
  require Aja

  def plain_indent_io(str, n) when is_integer(n),
    do: str |> plain_indent_io(String.duplicate(" ", n))

  def plain_indent_io(str, prefix) when is_binary(prefix) do
    bp = :binary.compile_pattern("\n")

    IO.iodata_to_binary(str)
    |> String.split(bp, trim: true)
    |> Enum.flat_map(&[prefix, &1, "\n"])
  end

  def plain_indent_bp_inline(str, n) when is_integer(n),
    do: str |> plain_indent_bp_inline(String.duplicate(" ", n))

  def plain_indent_bp_inline(str, prefix) when is_binary(prefix) do
    bp = :binary.compile_pattern("\n")

    IO.iodata_to_binary(str)
    |> String.split(bp, trim: true)
    |> Enum.flat_map(&[prefix, &1, "\n"])
  end

  def plain_indent_bp(str, n, bp) when is_integer(n),
    do: str |> plain_indent_bp(String.duplicate(" ", n), bp)

  def plain_indent_bp(str, prefix, bp) when is_binary(prefix) do
    IO.iodata_to_binary(str)
    |> String.split(bp, trim: true)
    |> Enum.flat_map(&[prefix, &1, "\n"])
  end

  def plain_indent_re(str, n, r) when is_integer(n),
    do: str |> plain_indent_re(String.duplicate(" ", n), r)

  def plain_indent_re(str, prefix, r) when is_binary(prefix) do
    str
    |> :re.split(r, [{:return, :list}, :trim])
    |> Enum.flat_map(&[prefix, &1, "\n"])
  end
end

r = S.text_chunk_regex(8)

inputs = %{
  "no newlines, 4 chars" => String.duplicate("x", 4) |> S.text_chunk(8, false, r),
  "16 newlines, 512 chars" =>
    String.duplicate(String.duplicate("x", 31) <> "\n", 16) |> S.text_chunk(8, false, r),
  "8 newlines, 1024 chars" =>
    String.duplicate(String.duplicate("x", 127) <> "\n", 8) |> S.text_chunk(8, false, r)
}

{:ok, r2} = :re.compile("\\n", [:multiline])
bp = :binary.compile_pattern("\n")

suites = %{
  # "Split with String" =>
  #   # identical to :binary.split()
  #   &T.plain_indent_io(&1, 2),
  "Split with String compiled in function" => &T.plain_indent_bp_inline(&1, 2),
  "Split with String precompiled" => &T.plain_indent_bp(&1, 2, bp)
  # "Split with :re" =>
  #  &T.plain_indent_re(&1, 2, r2)
}

Benchee.run(
  suites,
  inputs: inputs,
  time: 30,
  memory_time: 5,
  # profile_after: true,
  # profile_after: :fprof
  measure_function_call_overhead: true,
  pre_check: true
)
