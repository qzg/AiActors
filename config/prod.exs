import Config

config :ai_actors,
  # Production logging
  log_level: :info,
  # Shorter retention in production
  backup_retention_days: 7

# Configure logger for production
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]
