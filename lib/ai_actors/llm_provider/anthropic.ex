defmodule AiActors.LLMProvider.Anthropic do
  @moduledoc """
  Anthropic Claude API provider.

  Supports Claude Sonnet and Haiku models via direct API.
  """

  @behaviour AiActors.LLMProvider

  require Logger

  @api_base "https://api.anthropic.com/v1"
  @api_version "2023-06-01"
  @structured_outputs_beta "structured-outputs-2025-11-13"

  @models %{
    sonnet: "claude-sonnet-4-5-20250929",
    haiku: "claude-haiku-4-5-20250929",
    opus: "claude-opus-4-20250514"
  }

  @impl true
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
        Logger.error("Anthropic API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Anthropic request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def supported_models do
    Map.keys(@models)
  end

  @impl true
  def default_model do
    :sonnet
  end

  @doc """
  Get the actual model string for an alias.
  """
  def model_string(alias) when is_atom(alias) do
    Map.get(@models, alias, @models[:sonnet])
  end

  def model_string(model) when is_binary(model), do: model

  # Private functions

  defp get_api_key do
    config = AiActors.LLMProvider.get_provider_config(:anthropic)
    api_key_config = Keyword.get(config, :api_key, {:system, "ANTHROPIC_API_KEY"})
    AiActors.LLMProvider.resolve_api_key(api_key_config)
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

  defp build_request_body(messages, opts) do
    model_alias = Keyword.get(opts, :model, default_model())

    body = %{
      model: model_string(model_alias),
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

  defp transform_schema(schema) do
    ensure_additional_properties_false(schema)
  end

  defp ensure_additional_properties_false(schema) when is_map(schema) do
    schema =
      if Map.get(schema, :type) == "object" or Map.get(schema, "type") == "object" do
        Map.put(schema, :additionalProperties, false)
      else
        schema
      end

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
end
