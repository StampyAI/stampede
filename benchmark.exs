alias Stampede, as: S

split_size = 1999
max_pieces = 10
pre_compiled = Regex.compile!(".{#{split_size}}")

fake_work = fn chunks ->
  Enum.reduce(chunks, [], fn elem, lst ->
    Process.sleep(10)
    [elem | lst]
  end)
end

inputs = %{
  "small message" => div(split_size, 4) |> S.random_string_weak(),
  "medium message" => (split_size * 4) |> S.random_string_weak(),
  "large message" => (split_size * (max_pieces + div(max_pieces, 3))) |> S.random_string_weak(),
  "malicious message" => 9_999_999 |> S.random_string_weak()
}

Benchee.run(
  %{
    "String.split_at method" => fn txt ->
      S.text_split(txt, split_size, max_pieces)
      |> fake_work.()
    end,
    "regex method" => fn txt ->
      S.text_chunk(txt, split_size, max_pieces)
      |> fake_work.()
    end,
    "regex pre-compiled method" => fn txt ->
      S.text_chunk(txt, split_size, max_pieces, pre_compiled)
      |> fake_work.()
    end,
    "stream-based method" => fn txt ->
      S.stream_chunk(txt, split_size)
      |> Stream.take(max_pieces)
      |> fake_work.()
    end
  },
  inputs: inputs,
  time: 10,
  memory_time: 3
)
