# AiActors Examples

## Example 1: Smart Counter

A counter that understands natural language queries.

```elixir
defmodule Examples.SmartCounter do
  use AiActors.AiActor

  @impl true
  def init(initial \\ 0) do
    {:ok, %{count: initial, history: []}}
  end

  @impl true
  def development_metadata do
    %{
      purpose: "A counter with natural language query support",
      design_decisions: [
        "Track history for analytics",
        "Use LLM for complex queries about patterns"
      ],
      version: "1.0.0"
    }
  end

  # Explicit, fast handlers
  def handle_call({:increment, n}, _from, state) when is_number(n) do
    new_count = state.count + n
    new_history = state.history ++ [{:increment, n, DateTime.utc_now()}]
    new_state = %{state | count: new_count, history: new_history}
    {:reply, new_count, new_state}
  end

  def handle_call(:get, _from, state) do
    {:reply, state.count, state}
  end

  # Unknown queries go to LLM
  def handle_call(_msg, _from, _state) do
    :escalate_to_llm
  end
end

# Usage
{:ok, pid} = Examples.SmartCounter.start_link(0)

# Fast, explicit operations
GenServer.call(pid, {:increment, 5})  # => 5
GenServer.call(pid, {:increment, 10}) # => 15
GenServer.call(pid, :get)             # => 15

# Natural language via LLM
Examples.SmartCounter.ask_llm(
  pid,
  "How many times was the counter incremented by more than 7?"
)
# => {:ok, %{"content" => "Once, when you incremented by 10"}}
```

## Example 2: Task Manager with Custom Tools

A task manager that lets the LLM manipulate tasks.

```elixir
defmodule Examples.SmartTaskManager do
  use AiActors.AiActor

  @impl true
  def init(_) do
    {:ok, %{tasks: [], next_id: 1}}
  end

  @impl true
  def development_metadata do
    %{
      purpose: "Manage tasks with natural language interface",
      design_decisions: [
        "Auto-incrementing IDs",
        "LLM can create and modify tasks via tools"
      ],
      version: "1.0.0"
    }
  end

  # Define custom tools for the LLM
  @impl true
  def available_tools do
    AiActors.AiActor.default_tools() ++ [
      %{
        name: "create_task",
        description: "Create a new task",
        input_schema: %{
          type: "object",
          properties: %{
            title: %{type: "string"},
            priority: %{type: "string", enum: ["low", "medium", "high"]}
          },
          required: ["title"]
        }
      },
      %{
        name: "complete_task",
        description: "Mark a task as complete",
        input_schema: %{
          type: "object",
          properties: %{
            task_id: %{type: "integer"}
          },
          required: ["task_id"]
        }
      },
      %{
        name: "list_incomplete_tasks",
        description: "Get all incomplete tasks",
        input_schema: %{
          type: "object",
          properties: {}
        }
      }
    ]
  end

  # Implement tool execution
  @impl true
  def execute_tool("create_task", input, state) do
    task = %{
      id: state.user_state.next_id,
      title: input["title"],
      priority: input["priority"] || "medium",
      status: :pending,
      created_at: DateTime.utc_now()
    }

    new_state = %{
      state.user_state |
      tasks: state.user_state.tasks ++ [task],
      next_id: state.user_state.next_id + 1
    }

    {:ok, task, %{state | user_state: new_state}}
  end

  def execute_tool("complete_task", %{"task_id" => id}, state) do
    case Enum.find_index(state.user_state.tasks, &(&1.id == id)) do
      nil ->
        {:error, :task_not_found}

      idx ->
        task = Enum.at(state.user_state.tasks, idx)
        updated = %{task | status: :completed}
        new_tasks = List.replace_at(state.user_state.tasks, idx, updated)
        new_state = %{state.user_state | tasks: new_tasks}
        {:ok, updated, %{state | user_state: new_state}}
    end
  end

  def execute_tool("list_incomplete_tasks", _input, state) do
    incomplete = Enum.filter(
      state.user_state.tasks,
      &(&1.status == :pending)
    )
    {:ok, incomplete, state}
  end

  # Delegate to default tools or error
  def execute_tool(name, input, state) do
    AiActors.AiActor.execute_default_tool(name, input, state, __MODULE__)
  end
end

# Usage
{:ok, pid} = Examples.SmartTaskManager.start_link([])

# Natural language interaction
Examples.SmartTaskManager.ask_llm(
  pid,
  "Create three tasks: buy groceries, finish report, call mom. Make the report high priority."
)
# LLM will call create_task tool three times

Examples.SmartTaskManager.ask_llm(
  pid,
  "What tasks do I still need to do?"
)
# LLM will call list_incomplete_tasks tool
```

## Example 3: Self-Modifying Cache

A cache that can optimize itself based on usage patterns.

```elixir
defmodule Examples.SmartCache do
  use AiActors.AiActor

  @impl true
  def init(_) do
    {:ok, %{
      data: %{},
      stats: %{hits: 0, misses: 0},
      access_pattern: []
    }}
  end

  @impl true
  def development_metadata do
    %{
      purpose: "Intelligent cache that optimizes based on access patterns",
      design_decisions: [
        "Track access patterns for LLM analysis",
        "Allow LLM to suggest optimizations",
        "Support self-modification for performance tuning"
      ],
      version: "1.0.0"
    }
  end

  @impl true
  def available_tools do
    AiActors.AiActor.default_tools() ++ [
      %{
        name: "analyze_access_pattern",
        description: "Analyze cache access patterns and suggest optimizations",
        input_schema: %{
          type: "object",
          properties: %{
            time_window: %{type: "string", description: "Time window to analyze"}
          }
        }
      }
    ]
  end

  # Cache operations
  def handle_call({:get, key}, _from, state) do
    case Map.get(state.data, key) do
      nil ->
        new_stats = %{state.stats | misses: state.stats.misses + 1}
        new_pattern = state.access_pattern ++ [{key, :miss, DateTime.utc_now()}]
        new_state = %{state | stats: new_stats, access_pattern: new_pattern}
        {:reply, nil, new_state}

      value ->
        new_stats = %{state.stats | hits: state.stats.hits + 1}
        new_pattern = state.access_pattern ++ [{key, :hit, DateTime.utc_now()}]
        new_state = %{state | stats: new_stats, access_pattern: new_pattern}
        {:reply, {:ok, value}, new_state}
    end
  end

  def handle_call({:put, key, value}, _from, state) do
    new_data = Map.put(state.data, key, value)
    {:reply, :ok, %{state | data: new_data}}
  end

  # Performance analysis via LLM
  def handle_call(:analyze_performance, _from, _state) do
    :escalate_to_llm
  end

  def handle_call(_msg, _from, _state) do
    :escalate_to_llm
  end
end

# Usage
{:ok, pid} = Examples.SmartCache.start_link([])

# Normal cache operations
GenServer.call(pid, {:put, :user_1, %{name: "Alice"}})
GenServer.call(pid, {:get, :user_1})

# Ask for performance analysis
Examples.SmartCache.ask_llm(
  pid,
  """
  Analyze my cache performance and suggest optimizations.
  Consider adding an LRU eviction policy if the hit rate is low.
  If you think code changes would help, use the request_code_change tool.
  """
)
# LLM will analyze stats and potentially request code modifications
```

## Example 4: Distributed Coordinator

An actor that coordinates work across a cluster.

```elixir
defmodule Examples.WorkCoordinator do
  use AiActors.AiActor

  @impl true
  def init(_) do
    {:ok, %{
      workers: %{},
      pending_jobs: [],
      completed_jobs: []
    }}
  end

  @impl true
  def development_metadata do
    %{
      purpose: "Coordinate distributed work with intelligent job assignment",
      design_decisions: [
        "Use LLM to optimize job assignment",
        "Track worker capabilities",
        "Handle failures gracefully"
      ],
      dependencies: ["WorkerPool", "JobQueue"],
      version: "1.0.0"
    }
  end

  @impl true
  def available_tools do
    AiActors.AiActor.default_tools() ++ [
      %{
        name: "assign_job",
        description: "Assign a job to a worker",
        input_schema: %{
          type: "object",
          properties: %{
            job_id: %{type: "string"},
            worker_id: %{type: "string"},
            reason: %{type: "string"}
          },
          required: ["job_id", "worker_id"]
        }
      },
      %{
        name: "list_available_workers",
        description: "Get list of available workers",
        input_schema: %{type: "object", properties: {}}
      }
    ]
  end

  def handle_call({:register_worker, id, capabilities}, _from, state) do
    new_workers = Map.put(state.workers, id, %{
      capabilities: capabilities,
      current_job: nil,
      last_seen: DateTime.utc_now()
    })
    {:reply, :ok, %{state | workers: new_workers}}
  end

  def handle_call({:submit_job, job}, _from, state) do
    new_pending = state.pending_jobs ++ [job]
    {:reply, :ok, %{state | pending_jobs: new_pending}}
  end

  # Let LLM handle job assignment optimization
  def handle_call(:optimize_assignments, _from, _state) do
    :escalate_to_llm
  end

  def handle_call(_msg, _from, _state) do
    :escalate_to_llm
  end
end

# Usage
{:ok, pid} = Examples.WorkCoordinator.start_link([])

GenServer.call(pid, {:register_worker, "w1", [:cpu_intensive, :io_intensive]})
GenServer.call(pid, {:register_worker, "w2", [:io_intensive]})

GenServer.call(pid, {:submit_job, %{id: "j1", type: :cpu_intensive}})
GenServer.call(pid, {:submit_job, %{id: "j2", type: :io_intensive}})

# Ask LLM to optimize
Examples.WorkCoordinator.ask_llm(
  pid,
  """
  I have workers with different capabilities and pending jobs.
  Assign jobs optimally using the assign_job tool.
  Prefer workers that have matching capabilities.
  """
)
```

## Example 5: Integration with Claude Code

Using the two-phase workflow to create new components.

```elixir
# Phase 1: Design
{:ok, design} = AiActors.ClaudeIntegration.phase1_design(%{
  name: "RateLimiter",
  purpose: "Rate limiting with adaptive thresholds",
  requirements: [
    "Sliding window rate limiting",
    "Per-user and global limits",
    "Automatic threshold adjustment based on load",
    "Alert on threshold breaches"
  ],
  should_be_ai_actor: true,
  dependencies: ["Redis", "Alerting"],
  notes: "Should handle burst traffic gracefully"
})

# This creates a design document at:
# docs/designs/rate_limiter_design.md

# Phase 2: Implementation
# In a real workflow, this would spawn a Claude Code subagent
{:ok, impl} = AiActors.ClaudeIntegration.phase2_implementation(design, %{
  name: "RateLimiter",
  purpose: "Rate limiting with adaptive thresholds",
  should_be_ai_actor: true
  # ... rest of spec
})

# The subagent would:
# 1. Read the design document
# 2. Generate implementation code
# 3. Write module file
# 4. Write comprehensive tests
# 5. Return paths to created files
```

## Testing Examples

### Testing with Mocked LLM

```elixir
defmodule Examples.SmartCounterTest do
  use ExUnit.Case

  # Test explicit handlers (no LLM needed)
  test "increment works" do
    {:ok, pid} = Examples.SmartCounter.start_link(0)
    assert 5 == GenServer.call(pid, {:increment, 5})
  end

  # Test LLM escalation (mocked)
  test "unknown messages escalate" do
    {:ok, pid} = Examples.SmartCounter.start_link(0)

    # In real tests, you'd mock LLMClient
    # For now, just verify the escalation happens
    result = catch_exit(GenServer.call(pid, :unknown_message))
    assert result # Would timeout since no LLM configured
  end
end
```

### Integration Test with Real LLM

```elixir
@tag :integration
@tag timeout: 30_000
test "LLM can analyze patterns" do
  {:ok, pid} = Examples.SmartCounter.start_link(0)

  # Create some pattern
  GenServer.call(pid, {:increment, 5})
  GenServer.call(pid, {:increment, 10})
  GenServer.call(pid, {:increment, 15})

  # Ask LLM to analyze
  {:ok, response} = Examples.SmartCounter.ask_llm(
    pid,
    "What's the average increment amount?"
  )

  # Verify response
  assert response["content"] =~ "10"
end
```

## Example 6: Multi-Provider LLM Usage

Using different LLM providers for cost optimization.

```elixir
defmodule Examples.CostOptimizedActor do
  use AiActors.AiActor

  @impl true
  def init(_) do
    {:ok, %{queries: []}}
  end

  @impl true
  def development_metadata do
    %{
      purpose: "Demonstrate multi-provider LLM usage for cost optimization",
      version: "1.0.0"
    }
  end

  # Simple queries use local Ollama (free)
  def handle_call({:simple_query, question}, _from, state) do
    result = AiActors.LLMClient.send_message(
      [%{role: "user", content: question}],
      provider: :ollama,
      model: :granite_micro,
      max_tokens: 256
    )
    {:reply, result, state}
  end

  # Fast queries use Cerebras via OpenRouter
  def handle_call({:fast_query, question}, _from, state) do
    result = AiActors.LLMClient.send_message(
      [%{role: "user", content: question}],
      provider: :openrouter,
      model: :cerebras_llama70b,
      max_tokens: 512
    )
    {:reply, result, state}
  end

  # Complex queries use Claude (most capable)
  def handle_call({:complex_query, question}, _from, state) do
    result = AiActors.LLMClient.send_message(
      [%{role: "user", content: question}],
      provider: :anthropic,
      model: :sonnet,
      max_tokens: 4096
    )
    {:reply, result, state}
  end

  # Unknown queries escalate to full LLM
  def handle_call(_msg, _from, _state), do: :escalate_to_llm
end

# Usage
{:ok, pid} = Examples.CostOptimizedActor.start_link([])

# Free - Local Ollama (~50-200ms)
GenServer.call(pid, {:simple_query, "What is 2+2?"})

# Fast - Cerebras (~100-500ms, ~$0.001)
GenServer.call(pid, {:fast_query, "Summarize this paragraph..."})

# Capable - Claude (~1-5s, ~$0.01)
GenServer.call(pid, {:complex_query, "Analyze this code and suggest improvements..."})
```

## Example 7: Self-Learning with Shadow Mode

An actor that learns and validates handlers safely.

```elixir
defmodule Examples.ShadowLearningActor do
  use AiActors.AiActor

  @impl true
  def init(_) do
    {:ok, %{counter: 0, operations: []}}
  end

  @impl true
  def enable_self_learning?, do: true

  @impl true
  def self_learning_config do
    %{
      review_interval_hours: 4,           # Frequent reviews
      min_escalations_for_analysis: 5,    # Learn quickly
      pattern_threshold: 2,               # Low threshold
      validation_window_hours: 24
    }
  end

  @impl true
  def development_metadata do
    %{
      purpose: "Demonstrate shadow mode learning",
      design_decisions: [
        "Start with minimal handlers",
        "Let system learn common patterns",
        "Shadow mode validates before promotion"
      ],
      version: "1.0.0"
    }
  end

  # Only handle increment explicitly
  defp handle_call_impl({:increment, n}, _from, state) when is_number(n) do
    new_counter = state.counter + n
    {:reply, new_counter, %{state | counter: new_counter}}
  end

  # Everything else escalates - will be learned over time
  defp handle_call_impl(_msg, _from, _state), do: :escalate_to_llm

  defp handle_cast_impl(_msg, state), do: {:noreply, state}
  defp handle_info_impl(_msg, state), do: {:noreply, state}
end

# Usage
{:ok, pid} = Examples.ShadowLearningActor.start_link([])

# This is handled explicitly (fast)
GenServer.call(pid, {:increment, 5})  # => 5

# These escalate to LLM initially
GenServer.call(pid, {:multiply, 2})   # Escalates, ~1500ms
GenServer.call(pid, {:multiply, 3})   # Escalates, ~1500ms
GenServer.call(pid, {:multiply, 4})   # Escalates, ~1500ms

# After enough escalations, trigger review
{:ok, result} = Examples.ShadowLearningActor.trigger_review(pid)

# System analyzes {:multiply, :_number} pattern
# If responses are consistent, registers shadow handler

# Now {:multiply, n} runs in shadow mode:
# - Primary: Still uses LLM
# - Shadow: Tests generated handler in parallel
# - Results compared, stats tracked

# Check shadow stats
stats = AiActors.ShadowRunner.get_shadow_stats(
  Examples.ShadowLearningActor,
  {:multiply, :_number}
)
# => %{executions: 50, match_rate: 0.98, crash_rate: 0.0}

# When promotion criteria met (50+ runs, 98%+ match, <1% crash, 24h):
# Handler is promoted to primary
# {:multiply, n} now executes in ~1ms instead of ~1500ms
```

## Example 8: Multi-Tier Optimization in Action

Showing how patterns get optimized to different tiers.

```elixir
defmodule Examples.TieredOptimizationDemo do
  use AiActors.AiActor

  @impl true
  def init(_) do
    {:ok, %{data: %{}}}
  end

  @impl true
  def enable_self_learning?, do: true

  @impl true
  def self_learning_config do
    %{
      review_interval_hours: 2,
      min_escalations_for_analysis: 3,
      pattern_threshold: 2,
      validation_window_hours: 12
    }
  end

  @impl true
  def development_metadata do
    %{
      purpose: "Demonstrate multi-tier optimization selection",
      version: "1.0.0"
    }
  end

  # All messages escalate initially
  defp handle_call_impl(_msg, _from, _state), do: :escalate_to_llm
  defp handle_cast_impl(_msg, state), do: {:noreply, state}
  defp handle_info_impl(_msg, state), do: {:noreply, state}
end

# Simulation showing tier selection

# Pattern 1: Always returns same answer -> DETERMINISTIC
# {:get_constant, :pi} always returns 3.14159
# => Compiled to: defp handle_call_impl({:get_constant, :pi}, ...) do {:reply, 3.14159, state} end

# Pattern 2: Simple math, low tokens -> LOCAL LLM (Ollama)
# {:calculate, "2+2"} -> Uses granite_micro locally
# => Free, ~100ms latency

# Pattern 3: Moderate complexity -> ACCELERATED (Cerebras)
# {:summarize, text} -> Uses cerebras_llama70b
# => ~$0.001, ~300ms latency

# Pattern 4: Complex reasoning -> KEEP FULL LLM
# {:analyze_code, code} -> Keeps using Claude Sonnet
# => ~$0.01, ~2s latency, but most accurate

# Check what tier was selected for each pattern:
result = AiActors.OptimizationEvaluator.evaluate_pattern(
  Examples.TieredOptimizationDemo,
  {:get_constant, :_atom},
  escalation_history
)

case result do
  {:deterministic, code} -> IO.puts("Compile to code")
  {:local_llm, _, model} -> IO.puts("Use #{model} locally")
  {:accelerated_llm, _, model} -> IO.puts("Use #{model} via OpenRouter")
  :keep_current -> IO.puts("Keep using Claude")
end
```

## Best Practices from Examples

1. **Explicit handlers for known operations** - Fast and predictable
2. **LLM for unknown/complex queries** - Intelligent fallback
3. **Rich development metadata** - Helps LLM understand context
4. **Custom tools for domain operations** - Safe, typed interactions
5. **Track relevant metrics** - Enables LLM analysis
6. **Clear documentation** - Benefits both humans and LLM
7. **Use multi-tier optimization** - Reduce costs with appropriate tiers
8. **Enable shadow mode** - Validate handlers safely before promotion
9. **Choose providers wisely** - Local for simple, accelerated for moderate, full for complex
