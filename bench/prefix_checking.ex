alias Stampede, as: S
require Stampede.MsgReceived
require Aja

defmodule T do
  require Plugin
  require Aja

  def split_prefix_re(text, prefix) when is_struct(prefix, Regex) and is_binary(text) do
    case Regex.split(prefix, text, include_captures: true, capture: :first, trim: true) do
      [p, b] ->
        {p, b}

      [^text] ->
        {false, text}

      [] ->
        {false, text}
    end
  end

  def split_prefix(text, prefix) when is_binary(prefix) and is_binary(text) do
    case text do
      <<^prefix::binary-size(floor(bit_size(prefix) / 8)), _::binary>> ->
        {
          binary_part(text, 0, byte_size(prefix)),
          binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
        }

      not_prefixed ->
        {false, not_prefixed}
    end
  end

  def split_prefix(text, prefixes) when is_list(prefixes) and is_binary(text) do
    prefixes
    |> Enum.reduce(nil, fn
      _, {s, b} ->
        {s, b}

      p, nil ->
        {s, b} = split_prefix(text, p)
        if s, do: {s, b}, else: nil
    end)
    |> then(fn
      nil ->
        {false, text}

      {s, b} ->
        {s, b}
    end)
  end

  def make_input(pref, number) do
    for n <- 0..(number - 1) do
      Enum.at(pref, Integer.mod(n, length(pref))) <> String.duplicate("x", 16)
    end
  end
end

r = ~r/^[ab][cd]/
bl = ["ac", "bc", "ad", "bd"]
r2 = ~r/\!/
bl2 = ["!"]

inputs = %{
  "128 prefixed strings" => T.make_input(bl, 128),
  "128 non-prefixed" => Enum.map(0..127, fn _ -> String.duplicate("x", 18) end)
}

suites = %{
  "Regex split" => &Enum.map(&1, fn x -> T.split_prefix_re(x, r) end),
  "Binary match split" => &Enum.map(&1, fn x -> T.split_prefix(x, bl) end),
  "Single-case Regex split" => &Enum.map(&1, fn x -> T.split_prefix_re(x, r2) end),
  "Single-case Binary match split" => &Enum.map(&1, fn x -> T.split_prefix(x, bl2) end)
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
