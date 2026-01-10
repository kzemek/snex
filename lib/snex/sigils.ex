defmodule Snex.Sigils do
  @moduledoc """
  Sigils for creating `Snex.Code` structs.

  `~p` and `~P` sigils create `Snex.Code` structs with location metadata.
  This is used for accurate stacktraces on Python side.

      iex> Snex.pyeval(env, ~p"raise RuntimeError('test')")

      {:error,
      %Snex.Error{
      code: :python_runtime_error,
      reason: "test",
      traceback: [...,
        "  File \"/Users/me/snex/sigils.ex\", line 8, in <module>\n    raise RuntimeError(\"test\")\n",
        "RuntimeError: test\n"]
      }}
  """

  @doc """
  Handles the sigil `~p` for location-annotated Python code.

  Returns a `%Snex.Code{}` struct built from the given code, unescaping characters
  and replacing interpolations.

  Note: using interpolation with multi-line strings will break the mapping between what Python
  thinks is the line number, and the actual line number in the Elixir source file.
  """
  defmacro sigil_p(src, _opts) do
    location = Macro.Env.location(__CALLER__)
    file = location[:file]
    line = location[:line]

    quote bind_quoted: [src: src, file: file, line: line] do
      %Snex.Code{
        src: src,
        file: file,
        # heuristic: if the code ends with a newline, then assume we're
        # in a heredoc. In that case, code starts at next line from """
        line: line + if(String.ends_with?(src, "\n"), do: 1, else: 0)
      }
    end
  end

  @doc """
  Handles the sigil `~P` for location-annotated Python code.

  Returns a `%Snex.Code{}` struct built from the given code, without interpolations
  and without unescaping characters.
  """
  defmacro sigil_P(src, opts) do
    quote do
      sigil_p(unquote(src), unquote(opts))
    end
  end
end
