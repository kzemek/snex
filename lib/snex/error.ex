defmodule Snex.Error do
  @typedoc "The error code for a runtime error."
  @type python_runtime_error :: :python_runtime_error

  @typedoc "The error code for an internal error of Snex."
  @type internal_error :: :internal_error

  @typedoc """
  The error code indicating a `Snyx.Env` is not found in the Python interpreter
  that ran the command.
  """
  @type env_not_found :: :env_not_found

  @typedoc """
  The error code indicating a key is not found in the `Snyx.Env`.
  """
  @type env_key_not_found :: :env_key_not_found

  @typedoc """
  The error code for an unknown command.
  """
  @type code :: python_runtime_error() | internal_error() | env_not_found() | env_key_not_found()
  @type t :: %__MODULE__{code: code(), reason: String.t() | term()}

  defexception [:code, :reason]

  @spec from_raw(String.t(), any()) :: t()
  def from_raw(code, reason),
    do: %__MODULE__{code: String.to_atom(code), reason: reason}

  @impl Exception
  def message(%{code: code, reason: reason}) when is_binary(reason),
    do: "Snex.Error: #{code} #{reason}"

  def message(%{code: code, reason: reason}),
    do: "Snex.Error: #{code} #{inspect(reason)}"
end
