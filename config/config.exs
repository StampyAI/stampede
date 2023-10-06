import Config

config :logger, :console,
  level: :info,
  metadata: [:shard, :guild, :channel] # extra nostrum metadata

config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: false # may god have mercy on your soul

config :stampede, :logger, [
  {:handler, :file_log, :logger_std_h, %{
    config: %{
      file: ~c"logs/stampede.log",
      filesync_repeat_interval: 5000,
      file_check: 5000,
      max_no_bytes: 10_000_000,
      max_no_files: 5,
      compress_on_rotate: true
    },
    formatter: Logger.Formatter.new(
        format: {LogstashLoggerFormatter, :format},
        colors: [enabled: false],
        level: :all,
        metadata: [:shard, :guild, :channel,
          :stampede_component, :interaction_id]
      ),
  }}
]

config :nostrum,
  gateway_intents: :all

import_config("config.secret.exs")
