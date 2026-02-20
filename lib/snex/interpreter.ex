defmodule Snex.Interpreter do
  @moduledoc ~s'''
  Runs a Python interpreter in a separate OS process.

  This module is responsible for facilitating in-and-out communication between Elixir
  and the spawned Python interpreter.

  Usually you won't interact with this module directly.
  Instead, you would create a custom interpreter module with `use Snex.Interpreter`:

      defmodule SnexTest.NumpyInterpreter do
        use Snex.Interpreter,
          pyproject_toml: """
          [project]
          name = "my-numpy-project"
          version = "0.0.0"
          requires-python = "==3.11.*"
          dependencies = ["numpy>=2"]
          """
        end

  See the `m:Snex#module-custom-interpreter` module documentation for more detail.
  '''
  use GenServer

  alias Snex.Internal
  alias Snex.Internal.Command
  alias Snex.Internal.Commands
  alias Snex.Internal.TaskSupervisor

  require Logger

  @request 0
  @request_noreply 1
  @response 2
  @default_init_script_timeout to_timeout(minute: 1)
  @default_busy_limits_port {4096 * 1024, 8192 * 1024}

  @typedoc """
  Running instance of `Snex.Interpreter`.
  """
  @type server :: GenServer.server()

  @typep command ::
           Commands.Init.t()
           | Commands.MakeEnv.t()
           | Commands.Eval.t()
           | Commands.GC.t()
           | Commands.CallResponse.t()
           | Commands.CallErrorResponse.t()

  @typep request_id :: binary()

  # credo:disable-for-next-line
  alias __MODULE__, as: State
  defstruct [:port, :encoding_opts, pending: %{}]

  @typep state :: %State{
           port: port(),
           pending: %{optional(request_id()) => %{client: GenServer.from()}},
           encoding_opts: Snex.Serde.encoding_opts()
         }

  defmacro __using__(opts),
    do: Internal.CustomInterpreter.using(__CALLER__.module, opts)

  @type wrap_exec :: mfa() | (String.t(), [String.t()] -> {String.t(), [String.t()]})
  @type environment :: %{optional(String.t()) => String.t()}
  @type init_script ::
          String.t()
          | Snex.Code.t()
          | {String.t() | Snex.Code.t(), %{optional(String.t()) => any()}}

  @typedoc """
  See `:erlang.open_port/2` options for detailed documentation.

  `:busy_limits_port` is set to `#{inspect(@default_busy_limits_port)}` if not specified.
  The high watermark of this option is also used as the buffer limit on Python side.
  """
  @type port_opts ::
          {:parallelism, boolean()}
          | {:busy_limits_port, {non_neg_integer(), non_neg_integer()} | :disabled}
          | {:busy_limits_msgq, {non_neg_integer(), non_neg_integer()} | :disabled}

  @typedoc """
  Options for `start_link/1`.
  """
  @type option ::
          {:python, String.t()}
          | {:wrap_exec, wrap_exec()}
          | {:cd, Path.t()}
          | {:environment, environment()}
          | {:init_script, init_script()}
          | {:init_script_timeout, timeout()}
          | {:sync_start?, boolean()}
          | {:label, term()}
          | {:encoding_opts, Snex.Serde.encoding_opts()}
          | {:port_opts, port_opts()}
          | GenServer.option()

  @doc false
  @spec command(server(), port(), command(), Snex.Serde.encoding_opts(), timeout()) ::
          {:ok, term()} | {:error, Snex.Error.t() | term()}
  def command(interpreter, port, command, encoding_opts, timeout) do
    envs = Internal.Command.referenced_envs(command)

    deadline =
      if timeout == :infinity,
        do: :infinity,
        else: {:abs, System.monotonic_time(:millisecond) + timeout}

    id = generate_request_id()
    encoded_command = encode_command(command, @request, id, encoding_opts)
    request_id = :gen_server.send_request(interpreter, {:expect_reply, id})
    port_command_sync(port, encoded_command)

    case :gen_server.receive_response(request_id, deadline) do
      {:reply, reply} ->
        Snex.Env.touch(envs)
        decode_reply(reply)

      :timeout ->
        {:error, Snex.Error.exception(code: :response_timeout)}

      {:error, {reason, _server_ref}} ->
        {:error, Snex.Error.exception(code: :call_failed, reason: reason)}
    end
  end

  @doc false
  # command_noreply does not ensure envs will live until after the command is sent!
  @spec command_noreply(server(), port(), command(), Snex.Serde.encoding_opts()) :: :ok
  def command_noreply(interpreter, port, command, encoding_opts) do
    id = generate_request_id()
    encoded_command = encode_command(command, @request_noreply, id, encoding_opts)
    interpreter |> GenServer.whereis() |> port_command_async(port, encoded_command)
  end

  @doc false
  @spec get_settings(server()) :: %{port: port(), encoding_opts: Snex.Serde.encoding_opts()}
  def get_settings(interpreter),
    do: GenServer.call(interpreter, :get_settings)

  @doc """
  Returns the OS PID of the Python interpreter.
  """
  @spec os_pid(server()) :: non_neg_integer()
  def os_pid(interpreter),
    do: GenServer.call(interpreter, :os_pid)

  @doc """
  Stops the interpreter process with reason `reason`.

  Pending callers will return `{:error, %Snex.Error{code: :call_failed, reason: reason}}`.
  """
  @spec stop(server(), term(), timeout()) :: :ok
  def stop(interpreter, reason \\ :normal, timeout \\ :infinity),
    do: GenServer.stop(interpreter, reason, timeout)

  @doc """
  Starts a new Python interpreter.

  The interpreter can be used by functions in the `Snex` module.

  ## Options

    - `:python` (`t:String.t/0`) - The Python executable to use. This can be a full path
      or a command to find via `System.find_executable/1`.

    - `:wrap_exec` (`t:wrap_exec/0`) - A function to wrap the Python executable and arguments.
      It can be given as an MFA or a function that takes two arguments: the Python executable path
      and its arguments. If given as `{M,F,A}`, the arguments will be appended to the `A` argument
      list.

    - `:cd` (`t:String.t/0`) - The directory to change to before running the interpreter.

    - `:environment` (`t:environment/0`) - A map of environment variables to set when running
      the Python executable.

    - `:init_script` (`t:init_script/0`) - A string of Python code to run when the interpreter
      is started, or a tuple with `{python_code, additional_vars}`. `additional_vars` are additional
      variables that will be added to the root environment before running the script.

      The environment left by the script will be the initial context for all `Snex.make_env/3` calls
      using this interpreter. This includes the variables passed through `additional_vars`. E.g.:

          {:ok, inp} = Snex.Interpreter.start_link(init_script: {"y = 2 * x", %{"x" => 3}})
          # Any new `env` will already contain `x` and `y`
          {:ok, env} = Snex.make_env(inp)
          {:ok, {3, 6}} = Snex.pyeval(env, "return x, y")

      Failing to run the script will cause the process initialization to fail.

    - `:init_script_timeout` (`t:timeout/0`) - The timeout for the init script. Can be a number
      of milliseconds or `:infinity`. Default: #{@default_init_script_timeout}.

    - `:sync_start?` (`t:boolean/0`) - If `true`, the interpreter will start and run the init script
      in the `init/1` callback. Setting this to `false` is useful for long-running init scripts;
      the downside is that if something goes wrong, the interpreter process will start crashing
      after successfully starting as a part of the supervision tree. Default: `true`.

    - `:label` (`t:term/0`) - The label of the interpreter process. This label will be used to label
      the process through `:proc_lib.set_label/1`.

    - `:encoding_opts` (`t:Snex.Serde.encoding_opts/0`) - Options for encoding Elixir terms
      to a desired representation on the Python side. These settings will be used when encoding
      terms for this interpreter, but can be overridden by individual commands.

    - `:port_opts` (`t:port_opts/0`) - Advanced options for the port used to communicate with
      the Python interpreter.

    - any other options will be passed to `GenServer.start_link/3`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {args, genserver_opts} =
      Keyword.split(opts, [
        :python,
        :wrap_exec,
        :cd,
        :environment,
        :init_script,
        :init_script_timeout,
        :sync_start?,
        :label,
        :encoding_opts,
        :port_opts
      ])

    GenServer.start_link(__MODULE__, args, genserver_opts)
  end

  @impl GenServer
  @spec init([option()]) ::
          {:ok, state()} | {:ok, state(), {:continue, {:init, [option()]}}}
  def init(opts) do
    {label, opts} = Keyword.pop(opts, :label)
    {encoding_opts, opts} = Keyword.pop(opts, :encoding_opts, [])

    if label != nil and function_exported?(:proc_lib, :set_label, 1),
      do: :proc_lib.set_label(label)

    with true <- !!Keyword.get(opts, :sync_start?, true),
         {:ok, port} <- init_python_port(opts) do
      {:ok, %State{port: port, encoding_opts: encoding_opts}}
    else
      false -> {:ok, %State{encoding_opts: encoding_opts}, {:continue, {:init, opts}}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  @spec handle_continue({:init, [option()]}, state()) ::
          {:noreply, state()}
  def handle_continue({:init, opts}, %State{} = state) do
    case init_python_port(opts) do
      {:ok, port} -> {:noreply, %State{state | port: port}}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl GenServer
  @spec handle_call(:get_settings, GenServer.from(), state()) ::
          {:reply, %{port: port(), encoding_opts: Snex.Serde.encoding_opts()}, state()}
  def handle_call(:get_settings, _from, %State{} = state),
    do: {:reply, %{port: state.port, encoding_opts: state.encoding_opts}, state}

  @spec handle_call(:os_pid, GenServer.from(), state()) ::
          {:reply, non_neg_integer(), state()}
  def handle_call(:os_pid, _from, %State{port: port} = state) do
    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    {:reply, os_pid, state}
  end

  @spec handle_call({:expect_reply, request_id()}, GenServer.from(), state()) ::
          {:noreply, state()}
  def handle_call({:expect_reply, id}, from, %State{} = state) do
    pending = Map.put(state.pending, id, %{client: from})
    {:noreply, %State{state | pending: pending}}
  end

  @impl GenServer
  @spec handle_info({port(), {:data, binary()}}, state()) ::
          {:noreply, state()} | {:stop, {:exit_status, non_neg_integer()}, state()}
  def handle_info(
        {port, {:data, <<id::binary-size(16), @response, data::binary>>}},
        %State{port: port} = state
      )
      when is_map_key(state.pending, id) do
    {%{client: client}, pending} = Map.pop!(state.pending, id)
    GenServer.reply(client, data)
    {:noreply, %State{state | pending: pending}}
  end

  def handle_info({port, {:data, data}}, %State{port: port} = state) do
    args = [data, self(), state.port, state.encoding_opts]
    {:ok, _} = Task.Supervisor.start_child(TaskSupervisor, __MODULE__, :on_python_request, args)
    {:noreply, state}
  end

  @spec handle_info({port(), {:exit_status, integer()}}, state()) ::
          {:stop, Snex.Error.t(), state()}
  def handle_info({port, {:exit_status, _status} = reason}, %State{port: port} = state) do
    {:stop, Snex.Error.exception(code: :interpreter_exited, reason: reason), state}
  end

  @spec handle_info(any(), state()) :: {:noreply, state()}
  def handle_info(message, %State{} = state) do
    Logger.warning("Received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp init_python_port(opts) do
    python = System.find_executable(opts[:python] || "python")
    snex_pythonpath = Internal.Paths.snex_pythonpath()

    pythonpath =
      case opts[:environment]["PYTHONPATH"] || System.get_env("PYTHONPATH") do
        nil -> snex_pythonpath
        pythonpath -> "#{snex_pythonpath}:#{pythonpath}"
      end

    environment =
      opts
      |> Keyword.get(:environment, %{})
      |> Map.put("PYTHONPATH", pythonpath)
      |> Enum.map(fn {key, value} -> {~c"#{key}", ~c"#{value}"} end)

    additional_port_opts =
      opts
      |> Keyword.get(:port_opts, [])
      |> Keyword.take([:parallelism, :busy_limits_port, :busy_limits_msgq])
      |> Keyword.merge(Keyword.take(opts, [:cd]))
      |> Keyword.put_new(:busy_limits_port, @default_busy_limits_port)

    {_, high_watermark} = Keyword.fetch!(additional_port_opts, :busy_limits_port)

    default_args = ["-m", "snex", "--buffer-limit", to_string(high_watermark)]

    {exec, args} =
      case opts[:wrap_exec] do
        nil -> {python, default_args}
        {m, f, a} -> apply(m, f, a ++ [python, default_args])
        fun when is_function(fun, 2) -> fun.(python, default_args)
      end

    port =
      Port.open(
        {:spawn_executable, exec},
        [
          :binary,
          :exit_status,
          :nouse_stdio,
          :hide,
          packet: 4,
          env: environment,
          args: args
        ] ++ additional_port_opts
      )

    with :ok <- run_init_script(port, opts),
         do: {:ok, port}
  end

  defp run_init_script(port, opts) do
    {code, additional_vars} =
      case opts[:init_script] do
        {code, additional_vars} -> {code, additional_vars}
        code -> {code, %{}}
      end

    command = %Commands.Init{code: Snex.Code.wrap(code), additional_vars: additional_vars}

    id = generate_request_id()
    encoded_command = encode_command(command, @request, id, Keyword.get(opts, :encoding_opts, []))
    port_command_sync(port, encoded_command)

    init_script_timeout = Keyword.get(opts, :init_script_timeout, @default_init_script_timeout)

    receive do
      {^port, {:data, <<^id::binary, @response, response::binary>>}} ->
        {:ok, nil} = decode_reply(response)
        :ok

      {^port, {:exit_status, _status} = reason} ->
        {:error, Snex.Error.exception(code: :interpreter_exited, reason: reason)}
    after
      init_script_timeout ->
        {:error, Snex.Error.exception(code: :init_script_timeout)}
    end
  end

  defp port_command_sync(port, data) when node(port) == node(),
    do: Port.command(port, data)

  defp port_command_sync(port, data),
    do: port |> node() |> :erpc.call(Port, :command, [port, data])

  @doc false
  # `def` not `defp` because it's called from :erpc.cast
  @spec port_command_async(owner :: pid() | {atom(), node()} | nil, port(), iodata()) :: :ok
  def port_command_async({owner, node}, port, data) when node != node(),
    do: :erpc.cast(node, __MODULE__, :port_command_async, [{owner, node}, port, data])

  def port_command_async(owner, port, data) when is_pid(owner) and node(owner) != node(),
    do: owner |> node() |> :erpc.cast(__MODULE__, :port_command_async, [owner, port, data])

  def port_command_async({owner, node}, port, data) when is_atom(owner) and node == node(),
    do: owner |> Process.whereis() |> port_command_async(port, data)

  def port_command_async(owner, port, data) when is_pid(owner) do
    with :nosuspend <- Process.send(port, {owner, {:command, data}}, [:nosuspend]) do
      {:ok, _} =
        Task.Supervisor.start_child(
          TaskSupervisor,
          Kernel,
          :send,
          [port, {owner, {:command, data}}]
        )
    end

    :ok
  end

  def port_command_async(nil, _port, _data),
    do: :ok

  defp decode_reply(data) do
    case Snex.Serde.decode(data) do
      {:ok, reply} ->
        reply_to_result(reply)

      {:error, reason} ->
        error =
          Snex.Error.exception(
            code: :internal_error,
            reason: {:result_decode_error, reason, data}
          )

        {:error, error}
    end
  end

  defp reply_to_result(reply) do
    case reply do
      %{"type" => "ok", "value" => value} ->
        {:ok, value}

      %{"type" => "error", "code" => code, "reason" => reason} = data ->
        error =
          Snex.Error.exception(
            # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
            code: String.to_atom(code),
            reason: reason,
            traceback: data["traceback"]
          )

        {:error, error}

      value ->
        error = Snex.Error.exception(code: :internal_error, reason: {:unknown_format, value})
        {:error, error}
    end
  end

  @doc false
  # called by handle_info with request port data
  @spec on_python_request(binary(), pid(), port(), Snex.Serde.encoding_opts()) :: :ok
  def on_python_request(
        <<id::binary-size(16), @request, data::binary>>,
        owner,
        port,
        encoding_opts
      ) do
    {:ok, %{"type" => "call", "module" => m, "function" => f, "args" => a} = command} =
      Snex.Serde.decode(data)

    [m, f, node] =
      Enum.map([m, f, command["node"]], fn
        atom when is_atom(atom) -> atom
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        string when is_binary(string) -> String.to_atom(string)
      end)

    result_encoding_opts =
      Enum.map(command["result_encoding_opts"] || [], fn
        {k, v} when is_atom(v) -> {String.to_existing_atom(k), v}
        {k, v} when is_binary(v) -> {String.to_existing_atom(k), String.to_existing_atom(v)}
      end)

    result =
      if node in [nil, node()],
        do: apply(m, f, a),
        else: :erpc.call(node, m, f, a)

    command = %Commands.CallResponse{result: result}

    # as long as we don't let users control the encoding opts per Snex.Env,
    # state.encoding_opts === env.encoding_opts. OTOH if/when we give that option,
    # we'll need here the env.encoding_opts of the task that called `snex.call`.
    encoding_opts = Keyword.merge(encoding_opts, result_encoding_opts)
    encoded_command = encode_command(command, @response, id, encoding_opts)
    port_command_async(owner, port, encoded_command)

    :ok
  catch
    kind, error ->
      command = %Commands.CallErrorResponse{reason: Exception.format(kind, error, __STACKTRACE__)}
      encoded_command = encode_command(command, @response, id, [])
      port_command_async(owner, port, encoded_command)
  end

  def on_python_request(
        <<_id::binary-size(16), @request_noreply, data::binary>>,
        _owner,
        _port,
        _encoding_opts
      ) do
    {:ok, %{"type" => "cast", "module" => m, "function" => f, "args" => a} = command} =
      Snex.Serde.decode(data)

    [m, f, node] =
      Enum.map([m, f, command["node"]], fn
        atom when is_atom(atom) -> atom
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        string when is_binary(string) -> String.to_atom(string)
      end)

    if node in [nil, node()],
      do: apply(m, f, a),
      else: :erpc.cast(node, m, f, a)

    :ok
  end

  defp generate_request_id,
    do: :rand.bytes(16)

  defp encode_command(command, type, id, encoding_opts),
    do: [id, type, Command.encode(command, encoding_opts)]
end
