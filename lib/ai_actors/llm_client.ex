defmodule AiActors.LLMClient do
@moduledoc """
  Client for interacting with Claude API (Anthropic).

  Handles:
  - Message sending with structured output support (using Claude's native structured outputs)
  - Tool/function calling
  - Streaming responses (optional)
  """

  require Logger

  @api_base "https://api.anthropic.com/v1"
  @default_model "claude-sonnet-4-5-20250929"
  @api_version "2023-06-01"
  @structured_outputs_beta "structured-outputs-2025-11-13"

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
  Send a message to Claude with optional tools and system prompt.

  ## Options
  - `:model` - Model to use (default: #{@default_model})
  - `:max_tokens` - Maximum tokens in response (default: 4096)
  - `:temperature` - Sampling temperature (default: 1.0)
  - `:tools` - List of available tools
  - `:system` - System prompt
  - `:structured_output` - JSON schema for structured output (uses Claude's native structured outputs API)
  """
  @spec send_message(list(message()), keyword()) :: response()
  def send_message(messages, opts \\ []) do
    api_key = get_api_key()

    unless api_key do
      raise "ANTHROPIC_API_KEY environment variable not set"
    end

    body = build_request_body(messages, opts)
    use_structured_outputs = Keyword.has_key?(opts, :structured_output)

    headers = build_headers(api_key, use_structured_outputs)

    case Req.post("#{@api_base}/messages", json: body, headers: headers) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("LLM API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("LLM request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_headers(api_key, use_structured_outputs) do
    base_headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    if use_structured_outputs do
      [{"anthropic-beta", @structured_outputs_beta} | base_headers]
    else
      base_headers
    end
  end

  @doc """
  Send a message and handle tool calls in a loop until a final response is received.
  """
  @spec send_message_with_tools(list(message()), list(tool()), keyword(), function()) ::
          response()
  def send_message_with_tools(messages, tools, opts \\ [], tool_executor) do
    opts = Keyword.put(opts, :tools, tools)
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

  defp build_request_body(messages, opts) do
    body = %{
      model: Keyword.get(opts, :model, @default_model),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      temperature: Keyword.get(opts, :temperature, 1.0),
      messages: messages
    }

    body =
      if system = Keyword.get(opts, :system) do
        Map.put(body, :system, system)
      else
        body
      end

    body =
      if tools = Keyword.get(opts, :tools) do
        Map.put(body, :tools, tools)
      else
        body
      end

    body =
      if structured_schema = Keyword.get(opts, :structured_output) do
        # Use Claude's native structured outputs API
        # This guarantees schema-compliant JSON through constrained decoding
        output_format = %{
          type: "json_schema",
          schema: transform_schema(structured_schema)
        }

        Map.put(body, :output_format, output_format)
      else
        body
      end

    body
  end

  # Transform schema to ensure it meets Claude's structured output requirements
  defp transform_schema(schema) do
    schema
    |> ensure_additional_properties_false()
  end

  # Add additionalProperties: false to all object types for strict validation
  defp ensure_additional_properties_false(schema) when is_map(schema) do
    schema = 
      if Map.get(schema, :type) == "object" or Map.get(schema, "type") == "object" do
        Map.put(schema, :additionalProperties, false)
      else
        schema
      end

    # Recursively process nested schemas
    Enum.reduce(schema, %{}, fn
      {:properties, props}, acc when is_map(props) ->
        Map.put(acc, :properties, Map.new(props, fn {k, v} -> {k, ensure_additional_properties_false(v)} end))
      {"properties", props}, acc when is_map(props) ->
        Map.put(acc, "properties", Map.new(props, fn {k, v} -> {k, ensure_additional_properties_false(v)} end))
      {:items, items}, acc when is_map(items) ->
        Map.put(acc, :items, ensure_additional_properties_false(items))
      {"items", items}, acc when is_map(items) ->
        Map.put(acc, "items", ensure_additional_properties_false(items))
      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end
  defp ensure_additional_properties_false(value), do: value

  defp get_api_key do
    System.get_env("ANTHROPIC_API_KEY")
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
