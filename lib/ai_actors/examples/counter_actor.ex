defmodule AiActors.Examples.CounterActor do
  @moduledoc """
  Example AiActor that maintains a counter.

  Demonstrates:
  - Basic state management
  - Explicit message handlers
  - LLM escalation for unknown messages
  - Self-documenting metadata
  """

  use AiActors.AiActor

  @impl AiActors.AiActor
  def init(initial_value \\ 0) do
    {:ok, %{counter: initial_value, history: []}}
  end

  @impl AiActors.AiActor
  def development_metadata do
    %{
      purpose: "Maintain a counter with increment/decrement operations and full history",
      design_decisions: [
        "Store full history to allow audit trail",
        "Escalate unknown operations to LLM for intelligent handling"
      ],
      dependencies: ["AiActors.LLMClient", "AiActors.CodeModifier"],
      created_at: ~U[2025-01-15 00:00:00Z],
      version: "1.0.0",
      custom_metadata: %{
        operations: ["increment", "decrement", "get_value", "get_history"]
      }
    }
  end

  # Explicit handlers

  @doc """
  Increment the counter.
  """
  def handle_call({:increment, amount}, _from, state) when is_number(amount) do
    new_value = state.counter + amount

    new_history =
      state.history ++
        [
          %{
            operation: :increment,
            amount: amount,
            result: new_value,
            timestamp: DateTime.utc_now()
          }
        ]

    new_state = %{state | counter: new_value, history: new_history}
    {:reply, new_value, new_state}
  end

  @doc """
  Decrement the counter.
  """
  def handle_call({:decrement, amount}, _from, state) when is_number(amount) do
    new_value = state.counter - amount

    new_history =
      state.history ++
        [
          %{
            operation: :decrement,
            amount: amount,
            result: new_value,
            timestamp: DateTime.utc_now()
          }
        ]

    new_state = %{state | counter: new_value, history: new_history}
    {:reply, new_value, new_state}
  end

  @doc """
  Get the current counter value.
  """
  def handle_call(:get_value, _from, state) do
    {:reply, state.counter, state}
  end

  @doc """
  Get the full history of operations.
  """
  def handle_call(:get_history, _from, state) do
    {:reply, state.history, state}
  end

  # All other messages will be escalated to LLM via :escalate_to_llm
  def handle_call(_msg, _from, _state) do
    :escalate_to_llm
  end

  def handle_cast(_msg, _state) do
    :escalate_to_llm
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
