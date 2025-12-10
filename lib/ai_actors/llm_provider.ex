defmodule AiActors.LLMProvider do
  @moduledoc """
  Behaviour for LLM providers.

  Implementations handle communication with different LLM backends:
  - Anthropic (Claude) - Direct API
  - OpenRouter - Access to Cerebras, SambaNova, and other providers
  - Ollama - Local models like IBM Granite

  ## Implementing a Provider

      defmodule MyProvider do
        @behaviour AiActors.LLMProvider

        @impl true
        def send_message(messages, opts) do
          # Implementation
        end

        @impl true
        def supported_models do
          [:my_model_1, :my_model_2]
        end

        @impl true
        def default_model do
          :my_model_1
        end
      end
  """

  @type message :: %{role: String.t(), content: String.t() | list()}
  @type response :: {:ok, map()} | {:error, term()}

  @doc """
  Send a message to the LLM provider.

  ## Options
  - `:model` - Model to use (provider-specific)
  - `:max_tokens` - Maximum tokens in response
  - `:temperature` - Sampling temperature
  - `:system` - System prompt
  - `:tools` - List of available tools
  - `:structured_output` - JSON schema for structured output
  """
  @callback send_message(messages :: list(message()), opts :: keyword()) :: response()

  @doc """
  List of supported model aliases for this provider.
  """
  @callback supported_models() :: list(atom())

  @doc """
  Default model to use if none specified.
  """
  @callback default_model() :: atom()

  @doc """
  Get the provider module for a given provider name.
  """
  @spec get_provider(atom()) :: module() | nil
  def get_provider(provider_name) do
    case provider_name do
      :anthropic -> AiActors.LLMProvider.Anthropic
      :openrouter -> AiActors.LLMProvider.OpenRouter
      :ollama -> AiActors.LLMProvider.Ollama
      _ -> nil
    end
  end

  @doc """
  Find which provider supports a given model alias.
  """
  @spec find_provider_for_model(atom()) :: atom() | nil
  def find_provider_for_model(model_alias) do
    # Check each provider explicitly to avoid calling methods on potentially nil values
    cond do
      model_alias in AiActors.LLMProvider.Anthropic.supported_models() -> :anthropic
      model_alias in AiActors.LLMProvider.OpenRouter.supported_models() -> :openrouter
      model_alias in AiActors.LLMProvider.Ollama.supported_models() -> :ollama
      true -> nil
    end
  end

  @doc """
  Get configuration for a provider from application config.
  """
  @spec get_provider_config(atom()) :: keyword()
  def get_provider_config(provider_name) do
    config = Application.get_env(:ai_actors, :llm_providers, [])
    
    # Handle both keyword list and map configs
    case config do
      list when is_list(list) -> Keyword.get(list, provider_name, [])
      map when is_map(map) -> Map.get(map, provider_name, [])
      _ -> []
    end
  end

  @doc """
  Resolve API key from config (supports {:system, "ENV_VAR"} format).
  """
  @spec resolve_api_key(term()) :: String.t() | nil
  def resolve_api_key({:system, env_var}), do: System.get_env(env_var)
  def resolve_api_key(key) when is_binary(key), do: key
  def resolve_api_key(_), do: nil
end
