defmodule AiActors.LLMClient do
@moduledoc """
  Unified client for interacting with LLM providers.

  Supports multiple providers:
  - **Anthropic (Claude)** - Direct API for Claude Sonnet, Haiku, Opus
  - **OpenRouter** - Access to Cerebras, SambaNova, and other accelerated providers
  - **Ollama** - Local models like IBM Granite

  ## Provider Selection

  The provider can be specified explicitly or auto-detected from the model:

      # Explicit provider
      LLMClient.send_message(messages, provider: :anthropic, model: :sonnet)
      LLMClient.send_message(messages, provider: :ollama, model: :granite_micro)

      # Auto-detect provider from model
      LLMClient.send_message(messages, model: :cerebras_llama70b)  # Uses OpenRouter

  ## Features

  - Message sending with structured output support
  - Tool/function calling
  - Multi-provider abstraction
  - Automatic response normalization
  """

  require Logger

  alias AiActors.LLMProvider

@default_provider :anthropic

  @type message :: %{
          role: String.t(),
          content: String.t() | list()
        }

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @type response :: {:ok, map()} | {:error, term()}

  @doc """
  Send a message to an LLM provider.

  ## Options
  - `:provider` - Provider to use (:anthropic, :openrouter, :ollama). Auto-detected if model is specified.
  - `:model` - Model to use (provider-specific alias or string)
  - `:max_tokens` - Maximum tokens in response (default: 4096)
  - `:temperature` - Sampling temperature (default: 1.0)
  - `:tools` - List of available tools (Anthropic only currently)
  - `:system` - System prompt
  - `:structured_output` - JSON schema for structured output
  """
  @spec send_message(list(message()), keyword()) :: response()
  def send_message(messages, opts \\ []) do
    case resolve_provider(opts) do
      {:ok, provider_name, provider_module} ->
        log_level = System.get_env("LOG_LEVEL", "info")
        if log_level == "debug" do
          model = Keyword.get(opts, :model, provider_module.default_model())
          Logger.debug("LLMClient: Using provider #{provider_name}, model #{inspect(model)}")
        end

        provider_module.send_message(messages, opts)
        
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Send a message and handle tool calls in a loop until a final response is received.
  
  Note: Tool calling is currently only fully supported with Anthropic provider.
  """
  @spec send_message_with_tools(list(message()), list(tool()), keyword(), function()) ::
          response()
  def send_message_with_tools(messages, tools, opts \\ [], tool_executor) do
    # Tool calling works best with Anthropic
    opts = opts
    |> Keyword.put(:tools, tools)
    |> Keyword.put_new(:provider, :anthropic)
    
    do_tool_loop(messages, opts, tool_executor)
  end

  defp do_tool_loop(messages, opts, tool_executor, max_iterations \\ 10)
  defp do_tool_loop(_messages, _opts, _tool_executor, 0) do
    {:error, :too_many_tool_calls}
  end

  defp do_tool_loop(messages, opts, tool_executor, iterations_left) do
    case send_message(messages, opts) do
      {:ok, %{"content" => content, "stop_reason" => stop_reason} = response} ->
        case stop_reason do
          "tool_use" ->
            # Extract tool calls and execute them
            tool_results = execute_tools(content, tool_executor)

            # Add assistant message and tool results to conversation
            new_messages =
              messages ++
                [
                  %{role: "assistant", content: content},
                  %{role: "user", content: tool_results}
                ]

            # Continue the loop
            do_tool_loop(new_messages, opts, tool_executor, iterations_left - 1)

          _other ->
            # Final response
            {:ok, response}
        end

      error ->
        error
    end
  end

  defp execute_tools(content, tool_executor) do
    content
    |> Enum.filter(&is_map(&1) and Map.get(&1, "type") == "tool_use")
    |> Enum.map(fn %{"id" => id, "name" => name, "input" => input} ->
      result = tool_executor.(name, input)

      %{
        type: "tool_result",
        tool_use_id: id,
        content: Jason.encode!(result)
      }
    end)
  end

  # Resolve which provider to use based on options.
  # Returns {:ok, provider_name, provider_module} or {:error, reason}
  @spec resolve_provider(keyword()) :: {:ok, atom(), module()} | {:error, term()}
  defp resolve_provider(opts) do
    # If provider is explicitly specified, use it
    case Keyword.get(opts, :provider) do
      nil ->
        # Try to auto-detect from model
        case Keyword.get(opts, :model) do
          nil ->
            # Use default - always returns a valid module
            {:ok, @default_provider, LLMProvider.Anthropic}
          
          model when is_atom(model) ->
            # Try to find provider for this model alias
            case LLMProvider.find_provider_for_model(model) do
              nil -> 
                # Model not found in any provider, use default
                {:ok, @default_provider, LLMProvider.Anthropic}
              provider_name -> 
                resolve_known_provider(provider_name)
            end
          
          _model_string ->
            # Model string, use default provider
            {:ok, @default_provider, LLMProvider.Anthropic}
        end
      
      provider_name when is_atom(provider_name) ->
        resolve_known_provider(provider_name)
    end
  end
  
  # Resolve a known provider name to its module
  defp resolve_known_provider(provider_name) do
    case provider_name do
      :anthropic -> {:ok, :anthropic, LLMProvider.Anthropic}
      :openrouter -> {:ok, :openrouter, LLMProvider.OpenRouter}
      :ollama -> {:ok, :ollama, LLMProvider.Ollama}
      _ -> {:error, {:unknown_provider, provider_name}}
    end
  end

  @doc """
  Parse a structured JSON response from the LLM.
  Handles cases where JSON is embedded in markdown code blocks or surrounded by text.
  """
  @spec parse_structured_response(map()) :: {:ok, map()} | {:error, term()}
  def parse_structured_response(%{"content" => content}) do
    text =
      content
      |> Enum.filter(&is_map(&1) and Map.get(&1, "type") == "text")
      |> Enum.map(&Map.get(&1, "text"))
      |> Enum.join("\n")

    # Try parsing directly first
    case Jason.decode(text) do
      {:ok, data} ->
        {:ok, data}

      {:error, _} ->
        # Try to extract JSON from markdown code blocks
        extracted = extract_json_from_text(text)
        case Jason.decode(extracted) do
          {:ok, data} -> {:ok, data}
          {:error, _} = error -> error
        end
    end
  end

  # Extract JSON from text that may contain markdown code blocks or extra text
  defp extract_json_from_text(text) do
    cond do
      # Try markdown code block with json tag
      match = Regex.run(~r/```json\s*\n?(.*?)\n?```/s, text) ->
        Enum.at(match, 1) |> String.trim()

      # Try markdown code block without tag
      match = Regex.run(~r/```\s*\n?(\{.*?\})\n?```/s, text) ->
        Enum.at(match, 1) |> String.trim()

      # Try to find a JSON object in the text
      match = Regex.run(~r/(\{[\s\S]*\})/s, text) ->
        Enum.at(match, 1) |> String.trim()

      # Return original text if no pattern matches
      true ->
        String.trim(text)
    end
  end
end
