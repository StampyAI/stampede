import Config

config :stampede,
  services: [Services.Dummy],
  log_to_file: false,
  log_post_serious_errors: false,
  clear_state: true

config :stampede,
  test_loaded: true
