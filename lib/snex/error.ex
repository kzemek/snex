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

  defexception [:code, :reason, :traceback]

  @impl Exception
  def message(%__MODULE__{} = exc),
    do: "Snex.Error: #{exc.code} #{format_reason(exc.reason)}#{format_traceback(exc.traceback)}"

  defp format_reason(<<reason::binary>>), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp format_traceback(traceback) when is_list(traceback), do: Enum.join(["\n\n" | traceback])
  defp format_traceback(_traceback), do: nil
end
