defmodule AiActors.SelfLearning do
  @moduledoc """
  Self-learning capabilities for AiActors with multi-tier optimization.

  This module provides:
  - Periodic pattern analysis
  - Multi-tier optimization evaluation (deterministic → local LLM → accelerated → full)
  - Shadow mode validation before promotion
  - Handler generation and implementation
  - Performance monitoring
  - Automatic code improvement

  ## Optimization Tiers

  1. **Deterministic** - Algorithmically computable responses (~0 cost, microseconds)
  2. **Local LLM** - Simple reasoning via Granite/Ollama (~0 cost, <100ms)
  3. **Accelerated LLM** - Moderate complexity via Cerebras/SambaNova (fast, moderate cost)
  4. **Full LLM** - Complex reasoning via Claude Sonnet (full cost)

  ## Workflow

  1. **Track**: All LLM escalations are logged with patterns normalized
  2. **Analyze**: Periodically analyze logs to find common patterns
  3. **Evaluate**: Use OptimizationEvaluator to determine optimal tier
  4. **Shadow**: Register shadow handlers that run in parallel with primary
  5. **Validate**: Compare shadow results against primary in production
  6. **Promote**: After meeting criteria, promote shadow to primary handler
  7. **Iterate**: Continue learning from new data

  ## Configuration

  Enable self-learning in your AiActor:

      defmodule MyActor do
        use AiActors.AiActor

        def enable_self_learning?, do: true
        def self_learning_config do
          %{
            review_interval_hours: 24,
            min_escalations_for_analysis: 10,
            pattern_threshold: 3,
            validation_window_hours: 48
          }
        end
      end

  """

  require Logger

  alias AiActors.{EscalationTracker, OptimizationEvaluator, ShadowRunner}

  @type learning_config :: %{
          review_interval_hours: pos_integer(),
          min_escalations_for_analysis: pos_integer(),
          pattern_threshold: pos_integer(),
          validation_window_hours: pos_integer()
        }

  @default_config %{
    review_interval_hours: 24,
    min_escalations_for_analysis: 10,
    pattern_threshold: 3,
    validation_window_hours: 48
  }

  @doc """
  Start periodic self-learning for an actor.
  """
  @spec start_learning(pid(), module()) :: {:ok, reference()}
  def start_learning(actor_pid, actor_module) do
    config = get_learning_config(actor_module)

    # Schedule first review
    interval_ms = config.review_interval_hours * 60 * 60 * 1000
    timer_ref = Process.send_after(actor_pid, {:self_learning_review, actor_module}, interval_ms)

    Logger.info("Started self-learning for #{inspect(actor_module)} with #{config.review_interval_hours}h interval")

    {:ok, timer_ref}
  end

  @doc """
  Perform a self-learning review for an actor.

  This now uses the multi-tier optimization system:
  1. Analyzes escalation patterns
  2. Evaluates each pattern for optimization tier
  3. Registers shadow handlers for validated optimizations
  4. Checks existing shadows for promotion readiness
  """
  @spec perform_review(module()) :: {:ok, map()} | {:error, term()}
  def perform_review(actor_module) do
    Logger.info("Performing self-learning review for #{inspect(actor_module)}")

    with {:ok, analysis} <- EscalationTracker.analyze_patterns(actor_module),
         {:ok, shadow_registrations} <- evaluate_and_register_shadows(actor_module, analysis),
         {:ok, promotions} <- check_promotions(actor_module) do
      {:ok,
       %{
         analysis: analysis,
         shadow_registrations: shadow_registrations,
         promotions: promotions,
         status: :review_complete
       }}
    else
      error ->
        Logger.error("Self-learning review failed: #{inspect(error)}")
        error
    end
  end

  @doc """
  Evaluate patterns and register shadow handlers for promising optimizations.
  """
  @spec evaluate_and_register_shadows(module(), map()) :: {:ok, list(map())} | {:error, term()}
  def evaluate_and_register_shadows(actor_module, analysis) do
    config = get_learning_config(actor_module)
    
    # Get escalation patterns that meet threshold
    patterns = analysis.patterns || []
    
    eligible_patterns = Enum.filter(patterns, fn p ->
      p.count >= config.pattern_threshold
    end)

    if length(eligible_patterns) == 0 do
      Logger.info("No patterns meet threshold for #{inspect(actor_module)}")
      {:ok, []}
    else
      Logger.info("Evaluating #{length(eligible_patterns)} patterns for #{inspect(actor_module)}")

      registrations = Enum.flat_map(eligible_patterns, fn pattern_info ->
        # Get escalation history for this pattern
        escalations = EscalationTracker.get_escalations(actor_module)
        |> Enum.filter(fn e ->
          normalized = AiActors.AiActor.normalize_message_pattern(e.message)
          normalized == pattern_info.pattern
        end)

        # Skip if already has shadow
        if ShadowRunner.has_shadow?(actor_module, pattern_info.pattern) do
          Logger.debug("Shadow already exists for #{inspect(pattern_info.pattern)}")
          []
        else
          # Evaluate for optimization
          case OptimizationEvaluator.evaluate_pattern(actor_module, pattern_info.pattern, escalations) do
            {:deterministic, code} ->
              register_deterministic_shadow(actor_module, pattern_info.pattern, code)

            {:local_llm, prompt_template, model} ->
              register_llm_shadow(actor_module, pattern_info.pattern, :local_llm, prompt_template, :ollama, model)

            {:accelerated_llm, prompt_template, model} ->
              register_llm_shadow(actor_module, pattern_info.pattern, :accelerated_llm, prompt_template, :openrouter, model)

            :keep_current ->
              Logger.debug("Pattern #{inspect(pattern_info.pattern)} should keep using full LLM")
              []
          end
        end
      end)

      {:ok, registrations}
    end
  end

  @doc """
  Check existing shadows for promotion eligibility.
  """
  @spec check_promotions(module()) :: {:ok, list(map())} | {:error, term()}
  def check_promotions(actor_module) do
    shadows = ShadowRunner.list_shadows()
    |> Enum.filter(fn {module, _pattern, _spec} -> module == actor_module end)

    promotions = Enum.flat_map(shadows, fn {module, pattern, _spec} ->
      case ShadowRunner.get_shadow_stats(module, pattern) do
        {:ok, stats} ->
          if should_promote?(stats) do
            case ShadowRunner.promote_shadow(module, pattern) do
              {:ok, ref} ->
                Logger.info("Promoted shadow for #{inspect(module)}/#{inspect(pattern)}")
                [%{module: module, pattern: pattern, promotion_ref: ref, stats: stats}]

              {:error, reason} ->
                Logger.warning("Failed to promote shadow: #{inspect(reason)}")
                maybe_discard_shadow(module, pattern, stats, reason)
            end
          else
            Logger.debug("Shadow #{inspect(pattern)} not ready for promotion: #{inspect(stats)}")
            []
          end

        {:error, :not_found} ->
          []
      end
    end)

    {:ok, promotions}
  end

  # Register a deterministic shadow handler
  defp register_deterministic_shadow(actor_module, pattern, code) do
    handler_spec = %{
      type: :deterministic,
      code: code,
      prompt_template: nil,
      provider: nil,
      model: nil,
      created_at: DateTime.utc_now(),
      pattern_description: inspect(pattern)
    }

    case ShadowRunner.register_shadow(actor_module, pattern, handler_spec) do
      :ok ->
        Logger.info("Registered deterministic shadow for #{inspect(pattern)}")
        [%{pattern: pattern, type: :deterministic, status: :registered}]

      {:error, reason} ->
        Logger.warning("Failed to register shadow: #{inspect(reason)}")
        []
    end
  end

  # Register an LLM-based shadow handler
  defp register_llm_shadow(actor_module, pattern, type, prompt_template, provider, model) do
    handler_spec = %{
      type: type,
      code: nil,
      prompt_template: prompt_template,
      provider: provider,
      model: model,
      created_at: DateTime.utc_now(),
      pattern_description: inspect(pattern)
    }

    case ShadowRunner.register_shadow(actor_module, pattern, handler_spec) do
      :ok ->
        Logger.info("Registered #{type} shadow for #{inspect(pattern)} using #{provider}/#{model}")
        [%{pattern: pattern, type: type, provider: provider, model: model, status: :registered}]

      {:error, reason} ->
        Logger.warning("Failed to register shadow: #{inspect(reason)}")
        []
    end
  end

  defp should_promote?(stats) do
    config = ShadowRunner.get_config()

    stats.executions >= config.min_shadow_executions and
      stats.match_rate >= config.min_match_rate and
      stats.crash_rate <= config.max_crash_rate and
      sufficient_shadow_duration?(stats, config)
  end

  defp sufficient_shadow_duration?(stats, config) do
    case stats.first_execution_at do
      nil -> false
      first ->
        hours_elapsed = DateTime.diff(DateTime.utc_now(), first, :hour)
        hours_elapsed >= config.min_shadow_duration_hours
    end
  end

  defp maybe_discard_shadow(module, pattern, stats, _reason) do
    # Discard shadow if it has high crash rate or too many mismatches
    config = ShadowRunner.get_config()

    should_discard = 
      stats.crash_rate > config.max_crash_rate * 2 or
      stats.match_rate < config.min_match_rate * 0.5

    if should_discard do
      Logger.warning("Discarding shadow #{inspect(pattern)} due to poor performance")
      ShadowRunner.discard_shadow(module, pattern)
    end

    []
  end

  @doc """
  Implement recommended handlers for an actor (legacy function - now uses shadow system).
  """
  @spec implement_recommendations(module(), map()) :: {:ok, list(map())} | {:error, term()}
  def implement_recommendations(actor_module, analysis) do
    # Delegate to shadow-based implementation
    evaluate_and_register_shadows(actor_module, analysis)
  end

  @doc """
  Generate enhanced code with new handlers.
  """
  @spec generate_enhanced_code(module(), String.t(), list(map())) ::
          {:ok, String.t()} | {:error, term()}
  def generate_enhanced_code(_actor_module, current_code, recommendations) do
    prompt = """
    You are enhancing an Elixir AiActor module with new deterministic handlers.

    ## Current Code

    ```elixir
    #{current_code}
    ```

    ## Recommendations

    Add the following handlers based on pattern analysis:

    #{Enum.map_join(recommendations, "\n\n", fn rec ->
      """
      ### Pattern: #{rec["pattern"]}
      Rationale: #{rec["rationale"]}
      Speedup: #{rec["estimated_speedup"]}

      Suggested handler:
      ```elixir
      #{rec["handler_code"]}
      ```
      """
    end)}

    ## Instructions

    1. Add each recommended handler to the module
    2. Place new handlers BEFORE the generic escalation handler
    3. Ensure handlers are wrapped with tracking calls:
       ```elixir
       def handle_call(message, from, state) do
         start_time = System.monotonic_time(:millisecond)
         result = # ... your handler logic
         end_time = System.monotonic_time(:millisecond)

         AiActors.EscalationTracker.log_handler_execution(
           __MODULE__,
           self(),
           :handler_name,
           message,
           result,
           end_time - start_time,
           true  # or false if error
         )

         result
       end
       ```
    4. Preserve all existing handlers and module structure
    5. Maintain code style and documentation

    Return ONLY the complete updated module code.
    """

    case AiActors.LLMClient.send_message(
           [%{role: "user", content: prompt}],
           system: "You are an expert Elixir developer. Generate clean, well-documented code.",
           max_tokens: 8000
         ) do
      {:ok, response} ->
        new_code = extract_code_from_response(response)
        {:ok, new_code}

      error ->
        error
    end
  end

  @doc """
  Validate that newly implemented handlers are working correctly.
  """
  @spec validate_handlers(module(), list(map())) :: {:ok, map()} | {:error, term()}
  def validate_handlers(actor_module, implementations) do
    config = get_learning_config(actor_module)
    cutoff = DateTime.utc_now() |> DateTime.add(-config.validation_window_hours * 60 * 60, :second)

    # Get handler executions since implementation
    executions =
      AiActors.EscalationTracker.get_handler_executions(actor_module, since: cutoff)

    # Check success rate for each implementation
    validations =
      Enum.map(implementations, fn impl ->
        pattern_executions =
          Enum.filter(executions, fn ex ->
            # Match executions to this pattern
            matches_pattern?(ex.message, impl.pattern)
          end)

        success_count = Enum.count(pattern_executions, & &1.success)
        total_count = length(pattern_executions)

        success_rate = if total_count > 0, do: success_count / total_count, else: 0.0

        avg_time =
          if total_count > 0 do
            Enum.sum(Enum.map(pattern_executions, & &1.execution_time_ms)) / total_count
          else
            0
          end

        status =
          cond do
            total_count == 0 -> :no_data
            success_rate >= 0.95 and avg_time < 100 -> :excellent
            success_rate >= 0.90 -> :good
            success_rate >= 0.75 -> :acceptable
            true -> :needs_improvement
          end

        %{
          pattern: impl.pattern,
          executions: total_count,
          success_rate: success_rate,
          avg_execution_time_ms: avg_time,
          status: status,
          recommendation:
            if status == :needs_improvement do
              "Handler may need refinement or should revert to LLM escalation"
            else
              "Handler performing well"
            end
        }
      end)

    {:ok,
     %{
       actor_module: actor_module,
       validated_at: DateTime.utc_now(),
       validations: validations,
       overall_status: determine_overall_status(validations)
     }}
  end

  @doc """
  Schedule validation for implementations.
  """
  @spec schedule_validation(module(), list(map())) :: :ok
  def schedule_validation(actor_module, implementations) do
    if length(implementations) > 0 do
      config = get_learning_config(actor_module)
      delay_ms = config.validation_window_hours * 60 * 60 * 1000

      Task.start(fn ->
        Process.sleep(delay_ms)

        case validate_handlers(actor_module, implementations) do
          {:ok, validation_result} ->
            Logger.info("""
            Validation complete for #{inspect(actor_module)}:
            #{inspect(validation_result, pretty: true)}
            """)

            # If handlers need improvement, trigger another review
            if validation_result.overall_status == :needs_improvement do
              Logger.warning("Some handlers need improvement, scheduling review")
              perform_review(actor_module)
            end

          {:error, reason} ->
            Logger.error("Validation failed: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @doc """
  Generate a learning report for an actor.
  """
  @spec generate_report(module()) :: map()
  def generate_report(actor_module) do
    stats = AiActors.EscalationTracker.get_statistics(actor_module)

    %{
      module: actor_module,
      generated_at: DateTime.utc_now(),
      statistics: stats,
      performance_metrics: %{
        escalation_rate: calculate_escalation_rate(stats),
        handler_efficiency: calculate_handler_efficiency(stats),
        avg_response_time_ms: calculate_avg_response_time(stats)
      },
      learning_status: determine_learning_status(stats)
    }
  end

  # Private Functions

  defp get_learning_config(actor_module) do
    if function_exported?(actor_module, :self_learning_config, 0) do
      Map.merge(@default_config, actor_module.self_learning_config())
    else
      @default_config
    end
  end

  defp extract_code_from_response(response) do
    text =
      response["content"]
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
      |> Enum.map(&Map.get(&1, "text"))
      |> Enum.join("\n")

    # Extract from code blocks
    case Regex.run(~r/```(?:elixir)?\n(.*?)\n```/s, text) do
      [_, code] -> code
      nil -> text
    end
  end

  defp matches_pattern?(message, pattern_description) do
    # Simple pattern matching - could be enhanced
    String.contains?(inspect(message), pattern_description)
  end

  defp determine_overall_status(validations) do
    statuses = Enum.map(validations, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 in [:excellent, :good])) -> :healthy
      Enum.any?(statuses, &(&1 == :needs_improvement)) -> :needs_improvement
      Enum.all?(statuses, &(&1 == :no_data)) -> :insufficient_data
      true -> :acceptable
    end
  end

  defp calculate_escalation_rate(stats) do
    total = stats.total_escalations + stats.total_handler_executions

    if total > 0 do
      stats.total_escalations / total
    else
      1.0
    end
  end

  defp calculate_handler_efficiency(stats) do
    if stats.total_handler_executions > 0 do
      stats.handler_success_rate
    else
      0.0
    end
  end

  defp calculate_avg_response_time(stats) do
    total_escalations = stats.total_escalations
    total_handlers = stats.total_handler_executions

    if total_escalations + total_handlers > 0 do
      (stats.avg_escalation_time_ms * total_escalations +
         stats.avg_handler_time_ms * total_handlers) /
        (total_escalations + total_handlers)
    else
      0.0
    end
  end

  defp determine_learning_status(stats) do
    escalation_rate = calculate_escalation_rate(stats)

    cond do
      stats.total_escalations < 10 -> :learning_phase
      escalation_rate > 0.5 -> :needs_more_handlers
      escalation_rate < 0.1 -> :highly_optimized
      true -> :progressing_well
    end
  end
end
