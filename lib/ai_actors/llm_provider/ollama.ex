defmodule AiActors.LLMProvider.Ollama do
  @moduledoc """
  Ollama API provider for local models.

  Supports IBM Granite 4.0 models and other local models via Ollama.
  
  ## Setup
  
  1. Install Ollama: https://ollama.ai
  2. Pull a model: `ollama pull granite3.1-moe:3b`
  3. Ensure Ollama is running: `ollama serve`

  ## Granite 4.0 Models
  
  - `granite_small` - 32B total / 9B activated (MoE) - Enterprise workhorse
  - `granite_tiny` - 7B total / 1B activated (MoE) - Low latency
  - `granite_micro` - 3B dense - Function calling, fast inference
  """

  @behaviour AiActors.LLMProvider

  require Logger

  @default_base_url "http://192.168.9.129:11434"

  # Model aliases - configure custom models in application config
  @models %{
    granite_small: "granite4:small-h",
    granite_tiny: "granite4:small-h",
    granite_micro: "granite4:small-h",
    granite_1b: "granite4:small-h",
    llama3_8b: "llama3.1:8b",
    llama3_70b: "llama3.1:70b",
    mistral: "mistral:latest",
    codellama: "codellama:latest"
  }

  @impl true
  def send_message(messages, opts \\ []) do
    base_url = get_base_url()
    body = build_request_body(messages, opts)

    case Req.post("#{base_url}/api/chat", json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, normalize_response(response_body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        Logger.error("Ollama not running. Start with: ollama serve")
        {:error, {:connection_refused, "Ollama server not running at #{base_url}"}}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def supported_models do
    Map.keys(@models)
  end

  @impl true
  def default_model do
    :granite_micro
  end

  @doc """
  Get the actual model string for an alias.
  """
  def model_string(alias) when is_atom(alias) do
    config = AiActors.LLMProvider.get_provider_config(:ollama)
    
    # Handle both keyword list and map configs
    custom_models = case config do
      list when is_list(list) -> Keyword.get(list, :models, [])
      map when is_map(map) -> Map.get(map, :models, [])
      _ -> []
    end

    # Check custom config first, then fall back to defaults
    custom_model = case custom_models do
      list when is_list(list) -> Keyword.get(list, alias)
      map when is_map(map) -> Map.get(map, alias)
      _ -> nil
    end
    
    custom_model || Map.get(@models, alias, @models[:granite_micro])
  end

  def model_string(model) when is_binary(model), do: model

  @doc """
  Check if Ollama is available and a model is installed.
  """
  def check_availability(model_alias \\ :granite_micro) do
    base_url = get_base_url()
    model = model_string(model_alias)

    case Req.get("#{base_url}/api/tags") do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        model_names = Enum.map(models, & &1["name"])

        if Enum.any?(model_names, &String.starts_with?(&1, model)) do
          {:ok, :available}
        else
          {:error, {:model_not_found, model, model_names}}
        end

      {:ok, %{status: status}} ->
        {:error, {:api_error, status}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :ollama_not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp get_base_url do
    config = AiActors.LLMProvider.get_provider_config(:ollama)
    
    case config do
      list when is_list(list) -> Keyword.get(list, :base_url, @default_base_url)
      map when is_map(map) -> Map.get(map, :base_url, @default_base_url)
      _ -> @default_base_url
    end
  end

  defp build_request_body(messages, opts) do
    model_alias = Keyword.get(opts, :model, default_model())

    # Convert messages to Ollama format
    ollama_messages = Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg[:role] || msg["role"]),
        "content" => msg[:content] || msg["content"]
      }
    end)

    # Add system message if provided
    ollama_messages =
      if system = Keyword.get(opts, :system) do
        [%{"role" => "system", "content" => system} | ollama_messages]
      else
        ollama_messages
      end

    body = %{
      "model" => model_string(model_alias),
      "messages" => ollama_messages,
      "stream" => false,
      "options" => %{
        "temperature" => Keyword.get(opts, :temperature, 0.7),
        "num_predict" => Keyword.get(opts, :max_tokens, 2048)
      }
    }

    # Ollama supports JSON format for some models
    body =
      if Keyword.has_key?(opts, :structured_output) do
        Map.put(body, "format", "json")
      else
        body
      end

    body
  end

  # Normalize Ollama response to Anthropic-like format
  defp normalize_response(%{"message" => message} = response) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => message["content"]
        }
      ],
      "model" => response["model"],
      "stop_reason" => if(response["done"], do: "end_turn", else: "max_tokens"),
      "usage" => %{
        "input_tokens" => response["prompt_eval_count"] || 0,
        "output_tokens" => response["eval_count"] || 0
      }
    }
  end

  defp normalize_response(response), do: response
end
