defmodule AiActors.LLMProvider.OpenRouter do
  @moduledoc """
  OpenRouter API provider.

  Provides access to various models including:
  - Cerebras (ultra-fast inference)
  - SambaNova (accelerated inference)
  - And many other providers via unified API
  """

  @behaviour AiActors.LLMProvider

  require Logger

  @api_base "https://openrouter.ai/api/v1"

  @models %{
    # Cerebras models (ultra-fast)
    cerebras_llama70b: "cerebras/llama-3.3-70b",
    cerebras_llama8b: "cerebras/llama3.1-8b",
    
    # SambaNova models
    sambanova_llama405b: "sambanova/llama-3.1-405b-instruct",
    sambanova_llama70b: "sambanova/llama-3.1-70b-instruct",
    
    # Other fast/cheap options
    groq_llama70b: "groq/llama-3.3-70b-versatile",
    groq_llama8b: "groq/llama-3.1-8b-instant",
    
    # Claude via OpenRouter (fallback)
    claude_sonnet: "anthropic/claude-sonnet-4",
    claude_haiku: "anthropic/claude-haiku-4"
  }

  @impl true
  def send_message(messages, opts \\ []) do
    api_key = get_api_key()

    unless api_key do
      {:error, {:missing_api_key, "OPENROUTER_API_KEY environment variable not set"}}
    else
      body = build_request_body(messages, opts)
      headers = build_headers(api_key)

      case Req.post("#{@api_base}/chat/completions", json: body, headers: headers) do
        {:ok, %{status: 200, body: response_body}} ->
          {:ok, normalize_response(response_body)}

        {:ok, %{status: status, body: body}} ->
          Logger.error("OpenRouter API error: #{status} - #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("OpenRouter request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def supported_models do
    Map.keys(@models)
  end

  @impl true
  def default_model do
    :cerebras_llama70b
  end

  @doc """
  Get the actual model string for an alias.
  """
  def model_string(alias) when is_atom(alias) do
    Map.get(@models, alias, @models[:cerebras_llama70b])
  end

  def model_string(model) when is_binary(model), do: model

  # Private functions

  defp get_api_key do
    config = AiActors.LLMProvider.get_provider_config(:openrouter)
    api_key_config = Keyword.get(config, :api_key, {:system, "OPENROUTER_API_KEY"})
    AiActors.LLMProvider.resolve_api_key(api_key_config)
  end

  defp build_headers(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"HTTP-Referer", "https://github.com/ai_actors"},
      {"X-Title", "AiActors"}
    ]
  end

  defp build_request_body(messages, opts) do
    model_alias = Keyword.get(opts, :model, default_model())

    # Convert messages to OpenAI format
    openai_messages = Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg[:role] || msg["role"]),
        "content" => msg[:content] || msg["content"]
      }
    end)

    body = %{
      "model" => model_string(model_alias),
      "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
      "temperature" => Keyword.get(opts, :temperature, 1.0),
      "messages" => openai_messages
    }

    # Add system message if provided
    body =
      if system = Keyword.get(opts, :system) do
        system_msg = %{"role" => "system", "content" => system}
        Map.update!(body, "messages", fn msgs -> [system_msg | msgs] end)
      else
        body
      end

    # OpenRouter supports JSON mode for some models
    body =
      if Keyword.has_key?(opts, :structured_output) do
        Map.put(body, "response_format", %{"type" => "json_object"})
      else
        body
      end

    body
  end

  # Normalize OpenRouter response to Anthropic-like format
  defp normalize_response(%{"choices" => [%{"message" => message} | _]} = response) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => message["content"]
        }
      ],
      "model" => response["model"],
      "stop_reason" => "end_turn",
      "usage" => response["usage"]
    }
  end

  defp normalize_response(response), do: response
end
