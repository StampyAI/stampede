defmodule Stampede.Response do
  @moduledoc """
  The data type for choosing between possible responses to a message.

  A rough guide to confidence levels:
        0 -> "This message isn't meant for this module, I have no idea what to do with it"
        1 -> "I could give a generic reply if I have to, as a last resort"
        2 -> "I can give a slightly better than generic reply, if I have to. e.g. I realise this is a question
              but don't know what it's asking"
        3 -> "I can probably handle this message with ok results, but I'm a frivolous/joke module"
        4 ->
        5 -> "I can definitely handle this message with ok results, but probably other modules could too"
        6 -> "I can definitely handle this message with good results, but probably other modules could too"
        7 -> "This is a valid command specifically for this module, and the module is 'for fun' functionality"
        8 -> "This is a valid command specifically for this module, and the module is medium importance functionality"
        9 -> "This is a valid command specifically for this module, and the module is important functionality"
        10 -> "This is a valid command specifically for this module, and the module is critical functionality"
  """
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    confidence: _ :: number(),
    text: _ :: nil | TxtBlock.t(),
    origin_plug: _ :: module(),
    origin_msg_id: _ :: nil | S.msg_id(),
    why: [] :: S.traceback(),
    callback: nil :: nil | S.module_function_args(),
    channel_lock: false :: S.channel_lock_action()
  )

  @doc "makes a new Response but automatically tags the source module unless already being tagged"
  defmacro new(keys) do
    quote do
      struct!(
        unquote(__MODULE__),
        Keyword.put_new(unquote(keys), :origin_plug, __MODULE__)
      )
    end
  end

  # friendly reminder to admire the macros from afar, they are charming but they have teeth and a taste for blood
end
