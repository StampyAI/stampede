# Scratch file used for deciding between different algorithms.

alias Stampede, as: S

split_size = 1999
max_pieces = 10

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

pre_compiled = Regex.compile!("^(.{1,#{split_size}})(.*)", "us")
r2 = Regex.compile!("(.{1,#{split_size}})", "us")

Benchee.run(
  %{
    "regex split" => fn txt ->
      S.text_chunk_three(txt, split_size, max_pieces, r2)
      |> fake_work.()
    end,
    "regex scan" => fn txt ->
      S.text_chunk_two(txt, split_size, max_pieces, r2)
      |> fake_work.()
    end,
    "regex cons" => fn txt ->
      S.text_chunk(txt, split_size, max_pieces, pre_compiled)
      |> fake_work.()
    end
  },
  inputs: inputs,
  time: 20,
  reduction_time: 10,
  memory_time: 3
)
