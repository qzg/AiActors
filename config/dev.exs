import Config

config :ai_actors,
  # Enable verbose logging in development
  log_level: :debug,
  # Keep more backups in dev
  backup_retention_days: 90

# Configure logger for development
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :module, :function]
