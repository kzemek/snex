import Config

if config_env() == :test do
  config :logger, :default_formatter,
    format: "[$level] $message $metadata\n",
    metadata: [
      :file,
      :line,
      :python_module,
      :python_function,
      :python_logger_name,
      :python_log_level,
      :python_process_id,
      :python_thread_id,
      :python_thread_name,
      :python_task_name,
      :python_exception,
      :domain,
      :application,
      :extra_1,
      :default_2
    ]
end
