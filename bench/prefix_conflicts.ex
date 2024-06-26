alias Stampede, as: S
require Stampede.Events.MsgReceived
require Aja

defmodule T do
  require Plugin
  require Aja

  def check_prefixes_for_conflicts(prefixes) when is_list(prefixes) do
    all_but_first = Enum.drop(prefixes, 1)
    all_but_last = Enum.drop(prefixes, -1)

    Enum.find_value(all_but_first, :no_conflict, fn
      prefix_in_danger ->
        Enum.find_value(all_but_last, false, fn
          ^prefix_in_danger ->
            # we've caught up to ourselves
            false

          prefix_that_interrupts ->
            {false_or_prefix, mangled} = S.split_prefix(prefix_in_danger, prefix_that_interrupts)

            if false_or_prefix do
              {:conflict, prefix_in_danger, prefix_that_interrupts, mangled}
            else
              false
            end
        end)
    end)
  end

  @spec do_check_prefixes_for_conflicts(nonempty_list(binary())) ::
          :no_conflict
          | {:conflict, mangled_prefix :: binary(), prefix_responsible :: binary(),
             how_it_was_mangled :: binary()}
  def do_check_prefixes_for_conflicts([first | rest]) do
    do_check_prefixes_for_conflicts(first, rest)
  end

  def do_check_prefixes_for_conflicts(_final_prefix, []),
    do: :no_conflict

  def do_check_prefixes_for_conflicts(prefix_that_interrupts, latter_prefixes) do
    Enum.find_value(latter_prefixes, fn
      prefix_in_danger ->
        {false_or_prefix, mangled} = S.split_prefix(prefix_in_danger, prefix_that_interrupts)

        if false_or_prefix do
          {:conflict, prefix_in_danger, prefix_that_interrupts, mangled}
        else
          nil
        end
    end)
    |> case do
      nil ->
        [h | t] = latter_prefixes
        do_check_prefixes_for_conflicts(h, t)

      otherwise ->
        otherwise
    end
  end

  def check_prefixes_for_conflicts_vec(prefixes) do
    all_but_first = Aja.Vector.drop(prefixes, 1)
    all_but_last = Aja.Vector.drop(prefixes, -1)

    Aja.Enum.find_value(all_but_first, :no_conflict, fn
      prefix_in_danger ->
        Aja.Enum.find_value(all_but_last, false, fn
          ^prefix_in_danger ->
            # we've caught up to ourselves
            false

          prefix_that_interrupts ->
            {false_or_prefix, mangled} = S.split_prefix(prefix_in_danger, prefix_that_interrupts)

            if false_or_prefix do
              {:conflict, prefix_in_danger, prefix_that_interrupts, mangled}
            else
              false
            end
        end)
    end)
  end

  @spec do_check_prefixes_for_conflicts_vec_2(%Aja.Vector{}) ::
          :no_conflict
          | {:conflict, mangled_prefix :: binary(), prefix_responsible :: binary(),
             how_it_was_mangled :: binary()}
  def do_check_prefixes_for_conflicts_vec_2(vector) do
    first = Aja.Vector.first(vector)
    rest = Aja.Vector.drop(vector, 1)
    do_check_prefixes_for_conflicts_vec_2(first, rest)
  end

  def do_check_prefixes_for_conflicts_vec_2(v, prefix_that_interrupts_i) when Aja.vec_size(v),
    do: :no_conflict

  def do_check_prefixes_for_conflicts_vec_2(prefix_that_interrupts, latter_prefixes) do
    Aja.Enum.find_value(latter_prefixes, fn
      prefix_in_danger ->
        {false_or_prefix, mangled} = S.split_prefix(prefix_in_danger, prefix_that_interrupts)

        if false_or_prefix do
          {:conflict, prefix_in_danger, prefix_that_interrupts, mangled}
        else
          nil
        end
    end)
    |> case do
      nil ->
        h = Aja.Vector.first(latter_prefixes)
        t = Aja.Vector.drop(latter_prefixes, 1)
        do_check_prefixes_for_conflicts(h, t)

      otherwise ->
        otherwise
    end
  end

  def check_prefixes_for_conflicts_nitpick([_h | []]), do: :no_conflict

  def check_prefixes_for_conflicts_nitpick([prefix_that_interrupts | latter_prefixes]) do
    Enum.find_value(latter_prefixes, fn
      prefix_in_danger ->
        {false_or_prefix, mangled} = S.split_prefix(prefix_in_danger, prefix_that_interrupts)

        if false_or_prefix do
          {:conflict, prefix_in_danger, prefix_that_interrupts, mangled}
        else
          nil
        end
    end)
    |> case do
      nil ->
        check_prefixes_for_conflicts_nitpick(latter_prefixes)

      otherwise ->
        otherwise
    end
  end

  def make_input(pref, number) do
    for n <- 0..(number - 1) do
      Enum.at(pref, Integer.mod(n, length(pref))) <> String.duplicate("x", 16)
    end
  end
end

bl = ["ac", "bc", "cc", "aca", "ad", "bd", "cc"]
blv = bl |> Aja.Vector.new()

suites = %{
  "manual" => fn -> T.do_check_prefixes_for_conflicts(bl) end,
  "manual nitpick" => fn -> T.check_prefixes_for_conflicts_nitpick(bl) end
  # # slow
  # "find_value" => fn -> T.check_prefixes_for_conflicts(bl) end,
  # # Even slower
  # "vectorized find_value" => fn -> T.check_prefixes_for_conflicts_vec(blv) end,
  # "vectorized manual" => fn -> T.do_check_prefixes_for_conflicts_vec_2(blv) end,
}

Benchee.run(
  suites,
  time: 30,
  memory_time: 5,
  # profile_after: true,
  # profile_after: :fprof
  measure_function_call_overhead: true,
  pre_check: true
)
