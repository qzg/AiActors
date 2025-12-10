defmodule AiActors.Examples.LearningCounterActor do
  @moduledoc """
  Example AiActor with self-learning enabled.

  This counter starts with minimal explicit handlers and learns
  to handle common patterns deterministically over time.

  ## Learning Process

  1. Initially, most messages escalate to LLM
  2. After several escalations, patterns are identified
  3. Deterministic handlers are automatically generated
  4. New handlers are validated for correctness
  5. Actor becomes progressively faster and cheaper to run

  ## Usage

      {:ok, pid} = LearningCounterActor.start_link(0)

      # These will escalate to LLM initially
      GenServer.call(pid, {:multiply, 2})
      GenServer.call(pid, {:divide, 2})
      GenServer.call(pid, :reset)

      # After enough escalations, trigger a review
      LearningCounterActor.trigger_review(pid)

      # Check learning progress
      stats = LearningCounterActor.get_learning_stats(pid)

  """

  use AiActors.AiActor

  # Initialize user state - don't override init, override init_impl
  # Default value is handled by the caller - start_link(0) or start_link(initial_value)
  defp init_impl(initial_value) do
    {:ok, %{counter: initial_value, operations: []}}
  end

  @impl AiActors.AiActor
  def development_metadata do
    %{
      purpose: "A self-learning counter that evolves to handle common operations deterministically",
      design_decisions: [
        "Start with minimal handlers to demonstrate learning",
        "Track all operations for analysis",
        "Enable self-learning with 4-hour review intervals"
      ],
      dependencies: ["AiActors.LLMClient", "AiActors.EscalationTracker", "AiActors.SelfLearning"],
      created_at: ~U[2025-01-15 12:00:00Z],
      version: "1.0.0",
      custom_metadata: %{
        learning_enabled: true,
        initial_handlers: ["increment", "decrement", "get_value"],
        learnable_operations: ["multiply", "divide", "reset", "double", "halve"]
      }
    }
  end

  @impl AiActors.AiActor
  def enable_self_learning?, do: true

  @impl AiActors.AiActor
  def self_learning_config do
    %{
      review_interval_hours: 4,
      min_escalations_for_analysis: 5,
      pattern_threshold: 2,
      validation_window_hours: 24
    }
  end

  # Initial explicit handlers (minimal set) - use handle_call_impl to work with framework

  defp handle_call_impl({:increment, amount}, _from, state) when is_number(amount) do
    start_time = System.monotonic_time(:millisecond)

    new_value = state.counter + amount
    new_ops = state.operations ++ [{:increment, amount, DateTime.utc_now()}]
    new_state = %{state | counter: new_value, operations: new_ops}

    end_time = System.monotonic_time(:millisecond)

    AiActors.EscalationTracker.log_handler_execution(
      __MODULE__,
      self(),
      :increment,
      {:increment, amount},
      new_value,
      end_time - start_time,
      true
    )

    {:reply, new_value, new_state}
  end

  defp handle_call_impl({:decrement, amount}, _from, state) when is_number(amount) do
    start_time = System.monotonic_time(:millisecond)

    new_value = state.counter - amount
    new_ops = state.operations ++ [{:decrement, amount, DateTime.utc_now()}]
    new_state = %{state | counter: new_value, operations: new_ops}

    end_time = System.monotonic_time(:millisecond)

    AiActors.EscalationTracker.log_handler_execution(
      __MODULE__,
      self(),
      :decrement,
      {:decrement, amount},
      new_value,
      end_time - start_time,
      true
    )

    {:reply, new_value, new_state}
  end

  defp handle_call_impl(:get_value, _from, state) do
    {:reply, state.counter, state}
  end

  # All other messages escalate to LLM (where learning happens)
  defp handle_call_impl(_msg, _from, _state) do
    :escalate_to_llm
  end

  defp handle_cast_impl(_msg, _state) do
    :escalate_to_llm
  end

  defp handle_info_impl(_msg, state) do
    {:noreply, state}
  end

  # Public API

  @doc """
  Manually trigger a self-learning review.
  """
  def review(pid) do
    trigger_review(pid)
  end

  @doc """
  Get statistics about learning progress.
  """
  def learning_stats(pid) do
    get_learning_stats(pid)
  end

  @doc """
  Get a report on the actor's learning journey.
  """
  def learning_report do
    AiActors.SelfLearning.generate_report(__MODULE__)
  end
end
