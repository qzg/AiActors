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

## Best Practices from Examples

1. **Explicit handlers for known operations** - Fast and predictable
2. **LLM for unknown/complex queries** - Intelligent fallback
3. **Rich development metadata** - Helps LLM understand context
4. **Custom tools for domain operations** - Safe, typed interactions
5. **Track relevant metrics** - Enables LLM analysis
6. **Clear documentation** - Benefits both humans and LLM
