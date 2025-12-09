import Config

config :ai_actors,
  # Disable actual code modification in tests
  enable_code_modification: false,
  # Use faster timeouts in tests
  llm_timeout: 5_000

# Configure logger for tests
config :logger, level: :warning
