import Config

test_or_dev? = Mix.env() in [:test, :dev]

prod? = Mix.env() == :prod
test? = Mix.env() == :test

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

config :stampede, :type_check,
  enable_runtime_checks: test_or_dev?,
  debug: false

config :stampede, Stampede.Scheduler,
  jobs: [
    {"@daily", {Stampede.Interact, :clean_interactions!, []}}
  ]

config :logger, :console,
  level: :all,
  metadata: stampede_metadata ++ [:mfa]

config :logger,
  truncate: :infinity,
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
config :ex_unit,
  timeout: :infinity

# By default, Nostrum requires ffmpeg to use voice.
config :nostrum, :ffmpeg, false

config :stampede,
  compile_env: Mix.env(),
  services_to_install: [
    Services.Discord
  ],
  # What will actually be started by stampede
  services_to_start:
    (if test? do
       # NOTE: this will have to change if Service-specific tests start making sense
       [Services.Dummy]
     else
       :all
     end),
  config_dir:
    "./Sites" <>
      (if prod? do
         ""
       else
         "_#{Mix.env()}"
       end),
  # enable posting serious errors to the channel specified in :error_log_destination
  log_post_serious_errors: true,
  # enable file logging
  log_to_file: true,
  # clear tables associated with this compilation environment
  clear_state: false,
  error_log_destination: :unset,
  python_exe: System.fetch_env!("FLAKE_PYTHON"),
  python_plugin_dirs: ["./lib_py"]

env_specific_cfg =
  "./config_#{Mix.env()}.exs"
  |> Path.expand(__DIR__)

if File.exists?(env_specific_cfg) do
  import_config env_specific_cfg
end

for config <- "./*.secret.exs" |> Path.expand(__DIR__) |> Path.wildcard() do
  import_config config
end
