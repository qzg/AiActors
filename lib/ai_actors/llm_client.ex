defmodule AiActors.LLMClient do
  @moduledoc """
  Client for interacting with Claude API (Anthropic).

  Handles:
  - Message sending with structured output support
  - Tool/function calling
  - Streaming responses (optional)
  """

  require Logger

  @api_base "https://api.anthropic.com/v1"
  @default_model "claude-sonnet-4-5-20250929"
  @api_version "2023-06-01"

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
  - `:structured_output` - Schema for structured output via prompt caching
  """
  @spec send_message(list(message()), keyword()) :: response()
  def send_message(messages, opts \\ []) do
    api_key = get_api_key()

    unless api_key do
      raise "ANTHROPIC_API_KEY environment variable not set"
    end

    body = build_request_body(messages, opts)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

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
        # Add structured output instructions to system prompt
        structured_system = """
        You must respond with valid JSON matching this schema:
        #{Jason.encode!(structured_schema, pretty: true)}

        Respond ONLY with the JSON object, no other text.
        """

        existing_system = Map.get(body, :system, "")

        Map.put(body, :system, existing_system <> "\n\n" <> structured_system)
      else
        body
      end

    body
  end

  defp get_api_key do
    System.get_env("ANTHROPIC_API_KEY")
  end

  @doc """
  Parse a structured JSON response from the LLM.
  """
  @spec parse_structured_response(map()) :: {:ok, map()} | {:error, term()}
  def parse_structured_response(%{"content" => content}) do
    text =
      content
      |> Enum.filter(&is_map(&1) and Map.get(&1, "type") == "text")
      |> Enum.map(&Map.get(&1, "text"))
      |> Enum.join("\n")

    case Jason.decode(text) do
      {:ok, data} -> {:ok, data}
      {:error, _} = error -> error
    end
  end
end
