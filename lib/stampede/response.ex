defmodule Stampede.Response do
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S

  defstruct!(
    confidence: _ :: number(),
    text: _ :: nil | String.t(),
    origin_plug: _ :: module(),
    why: [] :: S.traceback(),
    callback: nil :: nil | S.module_function_args()
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
