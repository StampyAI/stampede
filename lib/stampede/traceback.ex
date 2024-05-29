defmodule Stampede.Traceback do
  @moduledoc """
  Build and convert symbolic representations of tracebacks.
  """
  @compile [:bin_opt_info, :recv_opt_info]
  use TypeCheck
  require Aja

  @type! trace_item :: tuple() | atom()
  @type! t :: %Aja.Vector{}

  defguard is_traceback(tb) when is_struct(tb, Aja.Vector)
  defguard is_stringified(tb) when is_list(tb)

  def new() do
    Aja.Vector.new()
  end

  def append(tb, item = %Aja.Vector{}) do
    Aja.Vector.concat(tb, item)
  end

  def append(tb, item) do
    Aja.Vector.append(tb, item)
  end

  @spec! to_txt_block(t() | trace_item()) :: TxtBlock.t()
  def to_txt_block(tb) when is_struct(tb, Aja.Vector) do
    tb
    |> Aja.Enum.flat_map(&do_single_transform/1)
  end

  @spec! do_single_transform(trace_item :: trace_item()) :: TxtBlock.t()
  def do_single_transform({:callback_called, text, why}) do
    [
      "\nTop response was a callback, so i called it. It responded with: \n",
      {:quote_block, text},
      "\nWhen asked why, it said:\n",
      {:quote_block, why}
    ]
  end

  def do_single_transform(:callback_called_and_declined) do
    [
      "\nTop response was a callback, so i called it. But it decided it had nothing to say."
    ]
  end

  def do_single_transform({:channel_lock_triggered, channel_id, m, f, text, why}) do
    [
      "Channel ",
      channel_id |> inspect(),
      "was locked to module ",
      m |> inspect(),
      ", function ",
      f |> inspect(),
      ", so we called it. In response it said:\n",
      {:quote_block, text},
      "\nIt excused its behavior by saying \"",
      why,
      "\""
    ]
  end

  def do_single_transform({:declined_to_answer, plug}) do
    [
      "\nWe asked ",
      plug |> inspect(),
      ", and it decided not to answer."
    ]
  end

  def do_single_transform({:timeout, plug}) do
    [
      "\nWe asked ",
      plug |> inspect(),
      ", but it timed out."
    ]
  end

  def do_single_transform({:replied_offering_callback, plug, confidence, why}) do
    [
      "\nWe asked ",
      plug |> inspect(),
      ", and it responded with confidence ",
      confidence |> inspect(),
      " offering a callback.\nWhen asked why, it said: \"",
      why,
      "\""
    ]
  end

  def do_single_transform({:replied_with_text, plug, confidence, text, why}) do
    [
      "\nWe asked ",
      plug |> inspect(),
      ", and it responded with confidence ",
      confidence |> inspect(),
      ":\n",
      {:quote_block, text},
      "When asked why, it said: \"",
      why,
      "\""
    ]
  end

  def do_single_transform({:plugin_errored, plug, val}) do
    [
      "\nWe asked ",
      plug |> inspect(),
      ", but there was an error of type ",
      val |> inspect(),
      ". Full details should have been logged to the error logging channel."
    ]
  end

  def do_single_transform({:response_was_chosen, response_log}) do
    List.insert_at(
      do_single_transform(response_log),
      -1,
      "\nWe chose this response."
    )
  end
end
