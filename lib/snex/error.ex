defmodule Snex.Error do
  @moduledoc """
  Domain-specific errors returned by `Snex`.
  """

  @typedoc "The error code for a runtime error."
  @type python_runtime_error :: :python_runtime_error

  @typedoc "The error code for an internal error of Snex."
  @type internal_error :: :internal_error

  @typedoc """
  The error code indicating an environment referenced by the passed in `t:Snex.env/0` is not found in
  the Python interpreter that ran the command.
  """
  @type env_not_found :: :env_not_found

  @typedoc """
  The error code indicating a key is not found in the `t:Snex.env/0`.
  """
  @type env_key_not_found :: :env_key_not_found

  @typedoc """
  Error codes for all errors.
  """
  @type error_code ::
          python_runtime_error() | internal_error() | env_not_found() | env_key_not_found()

  @typedoc """
  The type of `#{inspect(__MODULE__)}`.
  """
  @type t :: %__MODULE__{code: error_code(), reason: String.t() | term()}

  defexception [:code, :reason]

  @doc false
  @spec from_raw(String.t(), any()) :: t()
  def from_raw(code, reason) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    %__MODULE__{code: String.to_atom(code), reason: reason}
  end

  @impl Exception
  def message(%{code: code, reason: reason}) when is_binary(reason),
    do: "Snex.Error: #{code} #{reason}"

  def message(%{code: code, reason: reason}),
    do: "Snex.Error: #{code} #{inspect(reason)}"
end
