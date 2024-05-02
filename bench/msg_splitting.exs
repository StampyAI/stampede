alias Stampede, as: S

# 2nd place
text_chunk = fn text, len, max_pieces, premade_regex ->
    r = premade_regex

    Regex.scan(r, text, trim: true, capture: :all_but_first)
    |> Enum.take(max_pieces)
    |> Enum.map(&hd/1)
end

# 1st place
text_chunk_binary_part = fn text, len, max_pieces, premade_regex ->
  r = premade_regex

  Regex.scan(r, text, trim: true, capture: :all_but_first, return: :index)
  |> Enum.take(max_pieces)
  |> Enum.map(fn [{i, l}] ->
    binary_part(text, i, l)
  end)
end

defmodule T do
  # very distant last place
  def text_chunk_iter(text, len, max_pieces) when max_pieces > 0 do
    txt_length = String.length(text)
    do_text_chunk_iter(
      text,
      len,
      max_pieces,
      txt_length
    )
    |> Enum.reverse()
  end

  def do_text_chunk_iter(text, len, max_pieces, txt_length, acc \\ [])
  def do_text_chunk_iter(_text, _len, 0, _txt_length, acc), do: acc
  def do_text_chunk_iter(text, len, max_pieces, txt_length, acc)
      when max_pieces > 0 and txt_length < len, do: [text | acc]
  def do_text_chunk_iter(text, len, max_pieces, txt_length, acc)
      when max_pieces > 0 do
    if len > txt_length do
      [text | acc]
    else
      do_text_chunk_iter(
        String.slice(text, len, txt_length),
        len,
        max_pieces - 1,
        txt_length - len,
        [String.slice(text, 0..len) | acc]
      )
    end
  end
end

split_size = 1999
max_pieces = 10

fake_work = fn chunks ->
  Enum.reduce(chunks, [], fn elem, lst ->
    Process.sleep(10)
    unless is_binary(elem) do
      raise "bad split"
    end
    [elem | lst]
  end)
end

inputs = %{
  "small message" => div(split_size, 4) |> S.random_string_weak(),
  "medium message" => (split_size * 4) |> S.random_string_weak(),
  "large message" => (split_size * (max_pieces + div(max_pieces, 3))) |> S.random_string_weak(),
  "malicious message" => 9_999_999 |> S.random_string_weak()
}

reg = Regex.compile!("(.{1,#{split_size}})", "us")

Benchee.run(
  %{
    "regex scan" => fn txt ->
      text_chunk.(txt, split_size, max_pieces, reg)
      |> fake_work.()
    end,
    "regex index referencing" => fn txt ->
      text_chunk_binary_part.(txt, split_size, max_pieces, reg)
      |> fake_work.()
    end,
    "manual substrings" => fn txt ->
      T.text_chunk_iter(txt, split_size, max_pieces)
      |> fake_work.()
    end
  },
  inputs: inputs,
  time: 20,
  memory_time: 3,
  pre_check: true
)
