defmodule AiActors.SelfLearning do
  @moduledoc """
  Self-learning capabilities for AiActors.

  This module provides:
  - Periodic pattern analysis
  - Handler generation and implementation
  - Handler validation
  - Performance monitoring
  - Automatic code improvement

  ## Workflow

  1. **Track**: All LLM escalations and handler executions are logged
  2. **Analyze**: Periodically analyze logs to find common patterns
  3. **Generate**: Create deterministic handlers for common patterns
  4. **Implement**: Use CodeModifier to add new handlers
  5. **Validate**: Monitor new handlers to ensure correctness
  6. **Iterate**: Continue learning from new data

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
  """
  @spec perform_review(module()) :: {:ok, map()} | {:error, term()}
  def perform_review(actor_module) do
    Logger.info("Performing self-learning review for #{inspect(actor_module)}")

    with {:ok, analysis} <- AiActors.EscalationTracker.analyze_patterns(actor_module),
         {:ok, implementations} <- implement_recommendations(actor_module, analysis),
         :ok <- schedule_validation(actor_module, implementations) do
      {:ok,
       %{
         analysis: analysis,
         implementations: implementations,
         status: :review_complete
       }}
    else
      error ->
        Logger.error("Self-learning review failed: #{inspect(error)}")
        error
    end
  end

  @doc """
  Implement recommended handlers for an actor.
  """
  @spec implement_recommendations(module(), map()) :: {:ok, list(map())} | {:error, term()}
  def implement_recommendations(actor_module, analysis) do
    recommendations = analysis.recommendations || []

    if length(recommendations) == 0 do
      Logger.info("No recommendations to implement for #{inspect(actor_module)}")
      {:ok, []}
    else
      Logger.info("Implementing #{length(recommendations)} recommendations for #{inspect(actor_module)}")

      # Get current module source
      case AiActors.CodeModifier.get_module_source(actor_module) do
        {:ok, current_code} ->
          # Generate new code with additional handlers
          case generate_enhanced_code(actor_module, current_code, recommendations) do
            {:ok, new_code} ->
              # Request code modification
              case AiActors.CodeModifier.modify_code(
                     actor_module,
                     new_code,
                     %{
                       reason: "Self-learning: Adding deterministic handlers",
                       patterns: Enum.map(recommendations, & &1["pattern"]),
                       timestamp: DateTime.utc_now()
                     }
                   ) do
                {:ok, ref} ->
                  implementations =
                    Enum.map(recommendations, fn rec ->
                      %{
                        pattern: rec["pattern"],
                        modification_ref: ref,
                        implemented_at: DateTime.utc_now(),
                        validation_status: :pending
                      }
                    end)

                  {:ok, implementations}

                error ->
                  error
              end

            error ->
              error
          end

        error ->
          error
      end
    end
  end

  @doc """
  Generate enhanced code with new handlers.
  """
  @spec generate_enhanced_code(module(), String.t(), list(map())) ::
          {:ok, String.t()} | {:error, term()}
  def generate_enhanced_code(actor_module, current_code, recommendations) do
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
