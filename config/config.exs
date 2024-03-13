import Config

stampede_metadata = [
  :stampede_component,
  :stampede_service,
  :stampede_msg_id,
  :stampede_plugin,
  :interaction_id
]

nostrum_metadata = [:shard, :guild, :channel]

extra_metadata =
  [
    :crash_reason,
    :error_code,
    :file,
    :line
  ] ++
    stampede_metadata ++
    nostrum_metadata

config :stampede,
  compile_env: Mix.env()

config :logger, :console,
  level: :debug,
  # extra nostrum metadata
  metadata: extra_metadata

config :logger,
  handle_otp_reports: true,
  # may god have mercy on your soul
  handle_sasl_reports: false

config :stampede, :logger, [
  {:handler, :file_log, :logger_std_h,
   %{
     config: %{
       file: ~c"logs/#{Mix.env()}/#{node()}.log",
       filesync_repeat_interval: 5000,
       file_check: 5000,
       max_no_bytes: 10_000_000,
       max_no_files: 5,
       compress_on_rotate: true
     },
     formatter:
       Logger.Formatter.new(
         format: {LogstashLoggerFormatter, :format},
         colors: [enabled: false],
         level: :all,
         metadata: extra_metadata
       )
   }}
]

config :nostrum,
  gateway_intents: :all

config :mnesia,
  # Notice the single quotes
  dir: ~c".mnesia/#{Mix.env()}/#{node()}"

for config <- "./*.secret.exs" |> Path.expand(__DIR__) |> Path.wildcard() do
  import_config config
end
