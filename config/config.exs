import Config

# Extra metadata for the logger to keep
stampede_metadata = [
  :stampede_component,
  :stampede_msg_id,
  :stampede_plugin,
  :stampede_already_logged,
  :interaction_id
]

nostrum_metadata = [:guild, :channel]

extra_metadata =
  [
    :crash_reason,
    :error_code,
    :file,
    :line,
    :application,
    :mfa
  ] ++
    stampede_metadata ++
    nostrum_metadata

# Actually start configuring things
config :stampede,
  compile_env: Mix.env()

config :stampede, :type_check,
  enable_runtime_checks: Mix.env() in [:dev, :test],
  debug: false

config :stampede, Stampede.Scheduler,
  jobs: [
    {"@daily", {Stampede.Interact, :clean_interactions!, []}}
  ]

config :logger, :console,
  level: :all,
  metadata: stampede_metadata ++ [:mfa]

config :logger,
  handle_otp_reports: true,
  # this will spam a lot of messages
  handle_sasl_reports: false,
  compile_time_purge_matching:
    (if Mix.env() == :prod do
       [
         [level_lower_than: :info]
       ]
     else
       []
     end)

config :stampede, :logger, [
  {:handler, :file_log, :logger_std_h,
   %{
     config: %{
       # separate environment logs
       file: ~c"logs/#{Mix.env()}/#{node()}.log",
       filesync_repeat_interval: 5000,
       file_check: 5000,
       max_no_bytes: 10_000_000,
       max_no_files: 5,
       compress_on_rotate: true
     },
     formatter:
       Logger.Formatter.new(
         format: {Uinta.Formatter, :format},
         colors: [enabled: false],
         level: :all,
         metadata: :all
       )
   }}
]

# Discord bot needs these to work
config :nostrum,
  gateway_intents: :all

# Don't mix environment databases
config :mnesia,
  dir: ~c".mnesia/#{Mix.env()}/#{node()}"

# Avoid timeouts while waiting for user input in assert_value
config :ex_unit, timeout: :infinity

for config <- "./*.secret.exs" |> Path.expand(__DIR__) |> Path.wildcard() do
  import_config config
end
