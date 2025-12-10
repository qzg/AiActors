defmodule AiActors.OptimizationEvaluator do
  @moduledoc """
  Analyzes escalation patterns to determine optimal handling strategy.

  This module examines the history of LLM escalations for a pattern and recommends
  one of four optimization tiers:

  1. **Deterministic** - Responses are identical or algorithmically computable
  2. **Local LLM** - Simple reasoning, can use Granite/local models (~0 cost)
  3. **Accelerated LLM** - Moderate complexity, use Cerebras/SambaNova (fast, moderate cost)
  4. **Full LLM** - Complex reasoning, keep using Claude Sonnet (full cost)

  ## Evaluation Criteria

  - Response variance (identical responses → deterministic)
  - Response complexity (simple structure → simpler model)
  - State dependency (requires reasoning about state → full LLM)
  - Cost/benefit analysis (frequency × cost savings)

  ## Usage

      # Evaluate a pattern and get recommendation
      {:deterministic, code} = OptimizationEvaluator.evaluate_pattern(
        MyActor,
        {:multiply, :_number},
        escalation_history
      )

      # Test if simpler model can handle pattern
      {:ok, pass_rate} = OptimizationEvaluator.test_simpler_llm(
        pattern,
        examples,
        expected_outputs
      )
  """

  require Logger

  alias AiActors.LLMClient

  @type optimization_tier :: :deterministic | :local_llm | :accelerated_llm | :full_llm

  @type evaluation_result ::
          {:deterministic, String.t()}
          | {:local_llm, String.t(), atom()}
          | {:accelerated_llm, String.t(), atom()}
          | :keep_current

  @default_config %{
    # Response variance thresholds
    identical_response_threshold: 0.95,
    similar_structure_threshold: 0.80,

    # Minimum data requirements
    min_occurrences: 5,
    min_cost_savings: 0.001,

    # Complexity indicators
    max_tokens_for_local: 200,
    max_tokens_for_accelerated: 500,

    # Testing requirements
    test_sample_size: 10,
    min_pass_rate_local: 0.95,
    min_pass_rate_accelerated: 0.90
  }

  @doc """
  Evaluate a pattern and recommend an optimization tier.

  Returns one of:
  - `{:deterministic, code}` - Handler code to compile
  - `{:local_llm, prompt_template, model}` - Use local model with prompt
  - `{:accelerated_llm, prompt_template, model}` - Use accelerated provider
  - `:keep_current` - Keep using full LLM
  """
  @spec evaluate_pattern(module(), term(), list(map())) :: evaluation_result()
  def evaluate_pattern(module, pattern, escalation_history, config \\ @default_config) do
    log_level = System.get_env("LOG_LEVEL", "info")

    if log_level == "debug" do
      Logger.debug("Evaluating pattern #{inspect(pattern)} for #{inspect(module)} " <>
        "with #{length(escalation_history)} escalations")
    end

    # Filter to successful escalations only
    # Handle both :response and :llm_response keys for compatibility
    successful = Enum.filter(escalation_history, fn e ->
      response = get_response(e)
      match?({:ok, _}, response) or is_map(response)
    end)

    if length(successful) < config.min_occurrences do
      Logger.debug("Insufficient data for pattern #{inspect(pattern)}: #{length(successful)} < #{config.min_occurrences}")
      :keep_current
    else
      # Analyze response patterns
      analysis = analyze_responses(successful)

      cond do
        # Check for deterministic (identical responses)
        analysis.identical_rate >= config.identical_response_threshold ->
          Logger.info("Pattern #{inspect(pattern)} is deterministic (#{Float.round(analysis.identical_rate * 100, 1)}% identical)")
          generate_deterministic_handler(module, pattern, successful)

        # Check for local LLM suitability
        analysis.avg_response_tokens <= config.max_tokens_for_local and
        analysis.structure_similarity >= config.similar_structure_threshold ->
          Logger.info("Pattern #{inspect(pattern)} suitable for local LLM")
          test_and_recommend_local_llm(module, pattern, successful, config)

        # Check for accelerated LLM suitability
        analysis.avg_response_tokens <= config.max_tokens_for_accelerated and
        not analysis.requires_state_reasoning ->
          Logger.info("Pattern #{inspect(pattern)} suitable for accelerated LLM")
          test_and_recommend_accelerated_llm(module, pattern, successful, config)

        # Keep current
        true ->
          Logger.debug("Pattern #{inspect(pattern)} requires full LLM")
          :keep_current
      end
    end
  end

  @doc """
  Test if a simpler LLM can handle a pattern by running it against historical examples.
  """
  @spec test_simpler_llm(term(), list(map()), list(term()), keyword()) ::
          {:ok, float()} | {:error, term()}
  def test_simpler_llm(_pattern, examples, expected_outputs, opts \\ []) do
    provider = Keyword.get(opts, :provider, :ollama)
    model = Keyword.get(opts, :model, :granite_micro)
    prompt_template = Keyword.get(opts, :prompt_template)

    # Take a sample of examples
    sample_size = min(length(examples), Keyword.get(opts, :sample_size, 10))
    sample = Enum.take_random(Enum.zip(examples, expected_outputs), sample_size)

    results = Enum.map(sample, fn {example, expected} ->
      prompt = build_test_prompt(prompt_template, example)

      case LLMClient.send_message(
        [%{role: "user", content: prompt}],
        provider: provider,
        model: model,
        max_tokens: 1024
      ) do
        {:ok, response} ->
          actual = extract_response_value(response)
          {compare_outputs(actual, expected), actual, expected}

        {:error, _reason} ->
          {false, :error, expected}
      end
    end)

    passes = Enum.count(results, fn {passed, _, _} -> passed end)
    pass_rate = passes / sample_size

    Logger.debug("Simpler LLM test: #{passes}/#{sample_size} passed (#{Float.round(pass_rate * 100, 1)}%)")

    {:ok, pass_rate}
  end

  @doc """
  Generate deterministic handler code for a pattern.
  """
  @spec generate_deterministic_handler(module(), term(), list(map())) ::
          {:deterministic, String.t()} | :keep_current
  def generate_deterministic_handler(module, pattern, escalations) do
    # Get the most common response
    responses = Enum.map(escalations, fn e ->
      case get_response(e) do
        {:ok, resp} -> resp
        resp when is_map(resp) -> resp
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    # Group by response to find most common
    grouped = Enum.group_by(responses, & &1)
    {most_common_response, count} = Enum.max_by(grouped, fn {_, list} -> length(list) end)

    Logger.info("Most common response for #{inspect(pattern)} (#{count}/#{length(responses)} occurrences): #{inspect(most_common_response)}")

    # Generate handler code using LLM
    case generate_handler_code(module, pattern, escalations, most_common_response) do
      {:ok, code} -> {:deterministic, code}
      {:error, _reason} -> :keep_current
    end
  end

  @doc """
  Get configuration for optimization evaluation.
  """
  @spec get_config() :: map()
  def get_config do
    Application.get_env(:ai_actors, :optimization_config, @default_config)
  end

  # Private Functions

  # Helper to get response from escalation entry (handles both :response and :llm_response keys)
  defp get_response(e) do
    Map.get(e, :response) || Map.get(e, :llm_response)
  end

  defp analyze_responses(escalations) do
    responses = Enum.map(escalations, fn e ->
      case get_response(e) do
        {:ok, resp} -> resp
        resp when is_map(resp) -> resp
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    total = length(responses)

    # Calculate identical response rate
    grouped = Enum.group_by(responses, &normalize_response_for_comparison/1)
    {_, max_count} = Enum.max_by(grouped, fn {_, list} -> length(list) end, fn -> {nil, []} end)
    identical_rate = if total > 0, do: length(max_count) / total, else: 0

    # Calculate structure similarity
    structures = Enum.map(responses, &extract_structure/1)
    structure_groups = Enum.group_by(structures, & &1)
    {_, max_structure_count} = Enum.max_by(structure_groups, fn {_, list} -> length(list) end, fn -> {nil, []} end)
    structure_similarity = if total > 0, do: length(max_structure_count) / total, else: 0

    # Estimate average response tokens (rough estimate)
    avg_response_tokens = Enum.reduce(responses, 0, fn resp, acc ->
      acc + estimate_tokens(resp)
    end) / max(total, 1)

    # Check if responses reference state (rough heuristic)
    requires_state_reasoning = Enum.any?(escalations, fn e ->
      case get_response(e) do
        {:ok, %{"value" => value}} when is_binary(value) ->
          String.contains?(value, ["state", "current", "previous", "history"])
        _ -> false
      end
    end)

    %{
      total: total,
      identical_rate: identical_rate,
      structure_similarity: structure_similarity,
      avg_response_tokens: avg_response_tokens,
      requires_state_reasoning: requires_state_reasoning
    }
  end

  defp normalize_response_for_comparison(response) when is_map(response) do
    # Normalize for comparison - extract key fields
    Map.take(response, ["action", "value"])
  end

  defp normalize_response_for_comparison(response), do: response

  defp extract_structure(response) when is_map(response) do
    # Extract just the keys/structure, not values
    Map.keys(response) |> Enum.sort()
  end

  defp extract_structure(_), do: :unknown

  defp estimate_tokens(response) when is_map(response) do
    # Rough estimate: ~4 chars per token
    response
    |> Jason.encode!()
    |> String.length()
    |> div(4)
  end

  defp estimate_tokens(response) when is_binary(response) do
    div(String.length(response), 4)
  end

  defp estimate_tokens(_), do: 50

  defp test_and_recommend_local_llm(module, pattern, escalations, config) do
    # Build a prompt template for this pattern
    prompt_template = build_prompt_template(module, pattern, escalations)

    # Get examples and expected outputs
    {examples, expected} = extract_examples(escalations)

    # Test with local LLM
    case test_simpler_llm(pattern, examples, expected,
      provider: :ollama,
      model: :granite_micro,
      prompt_template: prompt_template,
      sample_size: config.test_sample_size
    ) do
      {:ok, pass_rate} when pass_rate >= config.min_pass_rate_local ->
        {:local_llm, prompt_template, :granite_micro}

      {:ok, _pass_rate} ->
        # Try accelerated instead
        test_and_recommend_accelerated_llm(module, pattern, escalations, config)

      {:error, :ollama_not_running} ->
        # Ollama not available, try accelerated
        Logger.warning("Ollama not available, trying accelerated LLM")
        test_and_recommend_accelerated_llm(module, pattern, escalations, config)

      {:error, reason} ->
        Logger.warning("Local LLM test failed: #{inspect(reason)}")
        :keep_current
    end
  end

  defp test_and_recommend_accelerated_llm(module, pattern, escalations, config) do
    prompt_template = build_prompt_template(module, pattern, escalations)
    {examples, expected} = extract_examples(escalations)

    # Test with accelerated LLM (Cerebras via OpenRouter)
    case test_simpler_llm(pattern, examples, expected,
      provider: :openrouter,
      model: :cerebras_llama70b,
      prompt_template: prompt_template,
      sample_size: config.test_sample_size
    ) do
      {:ok, pass_rate} when pass_rate >= config.min_pass_rate_accelerated ->
        {:accelerated_llm, prompt_template, :cerebras_llama70b}

      {:ok, _pass_rate} ->
        :keep_current

      {:error, reason} ->
        Logger.warning("Accelerated LLM test failed: #{inspect(reason)}")
        :keep_current
    end
  end

  defp build_prompt_template(module, pattern, escalations) do
    # Get a few examples to include in the prompt
    examples = escalations
    |> Enum.take(3)
    |> Enum.map(fn e ->
      response = case get_response(e) do
        {:ok, resp} -> resp
        resp -> resp
      end
      "Input: #{inspect(e.message)}\nOutput: #{Jason.encode!(response)}"
    end)
    |> Enum.join("\n\n")

    """
    You are handling messages for #{inspect(module)}.
    Pattern: #{inspect(pattern)}

    Examples of correct responses:
    #{examples}

    Now handle this message:
    {{message}}

    Respond with JSON in the same format as the examples.
    """
  end

  defp extract_examples(escalations) do
    examples = Enum.map(escalations, & &1.message)
    expected = Enum.map(escalations, fn e ->
      case get_response(e) do
        {:ok, resp} -> resp
        resp -> resp
      end
    end)
    {examples, expected}
  end

  defp build_test_prompt(template, message) when is_binary(template) do
    String.replace(template, "{{message}}", inspect(message))
  end

  defp build_test_prompt(nil, message) do
    "Process this message and return a JSON response: #{inspect(message)}"
  end

  defp extract_response_value(%{"content" => content}) do
    text = content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.join("\n")

    case Jason.decode(text) do
      {:ok, data} -> data
      {:error, _} -> text
    end
  end

  defp extract_response_value(other), do: other

  defp compare_outputs(actual, expected) do
    # Flexible comparison - normalize and compare key fields
    normalized_actual = normalize_for_comparison(actual)
    normalized_expected = normalize_for_comparison(expected)

    normalized_actual == normalized_expected
  end

  defp normalize_for_comparison(value) when is_map(value) do
    # Compare action and value fields, ignore others
    %{
      action: Map.get(value, "action") || Map.get(value, :action),
      value: Map.get(value, "value") || Map.get(value, :value)
    }
  end

  defp normalize_for_comparison(value), do: value

  defp generate_handler_code(module, pattern, escalations, common_response) do
    # Get example messages
    examples = escalations
    |> Enum.take(5)
    |> Enum.map(fn e ->
      response = case get_response(e) do
        {:ok, resp} -> resp
        resp -> resp
      end
      "  # Message: #{inspect(e.message)} -> #{inspect(response)}"
    end)
    |> Enum.join("\n")

    prompt = """
    Generate an Elixir function clause for a GenServer handle_call_impl that handles
    the pattern #{inspect(pattern)} deterministically.

    Module: #{inspect(module)}

    Example messages and their responses:
    #{examples}

    Most common response: #{inspect(common_response)}

    Requirements:
    1. The function should be a `defp handle_call_impl/3` clause
    2. Pattern match on the message structure
    3. Return the appropriate response based on the input
    4. Use {:reply, result, state} format
    5. Handle the computation deterministically (no LLM calls)

    Return ONLY the function code, no explanation.
    """

    case LLMClient.send_message(
      [%{role: "user", content: prompt}],
      system: "You are an expert Elixir developer. Return only valid Elixir code.",
      max_tokens: 2000
    ) do
      {:ok, response} ->
        code = extract_code_from_response(response)
        {:ok, code}

      {:error, reason} ->
        Logger.error("Failed to generate handler code: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_code_from_response(%{"content" => content}) do
    text = content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.join("\n")

    case Regex.run(~r/```(?:elixir)?\n(.*?)\n```/s, text) do
      [_, code] -> code
      nil -> text
    end
  end
end
