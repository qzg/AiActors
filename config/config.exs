import Config

# Configure AiActors
config :ai_actors,
  # LLM Configuration
  llm_model: "claude-sonnet-4-5-20250929",
  max_tokens: 4096,
  temperature: 1.0,
  # Code modification safety
  enable_code_modification: true,
  backup_retention_days: 30

# Import environment-specific config
import_config "#{config_env()}.exs"
