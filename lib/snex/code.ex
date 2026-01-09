defmodule Snex.Code do
  @moduledoc """
  Struct representing a Python code snippet.

  The location metadata is used for accurate stacktraces on Python side.
  Usually created automatically by `~p"my code"` sigil from `Snex.Sigils`.
  """

  @type t :: %__MODULE__{
          src: iodata(),
          file: String.t(),
          line: non_neg_integer()
        }

  @enforce_keys [:src]
  defstruct [:src, file: "<Snex.Code>", line: 0]

  @doc """
  Ensures a code snippet is wrapped in a `Snex.Code` struct.
  """
  @spec wrap(nil) :: nil
  @spec wrap(iodata() | t()) :: t()
  def wrap(nil), do: nil
  def wrap(%__MODULE__{} = code), do: code
  def wrap(code), do: %__MODULE__{src: code}

  defimpl Snex.Serde.Encoder do
    @impl Snex.Serde.Encoder
    def encode(%Snex.Code{src: src, file: file, line: line}),
      do: %{"src" => Snex.Serde.binary(src, :str), "file" => file, "line" => line}
  end
end
