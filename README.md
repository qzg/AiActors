# AiActors

An Elixir framework for building intelligent GenServers that leverage Large Language Models (LLMs) to enhance their behavior.

## Overview

AiActors extends the OTP GenServer pattern with AI capabilities, enabling actors to:

- 🧠 **Escalate unhandled messages to LLM** - Unknown operations are intelligently handled
- 🔧 **Self-modify their code** - Actors can request changes to their own implementation
- 📚 **Track development context** - Maintain metadata about design decisions and implementation
- 🛠️ **Provide tools to LLM** - Define domain-specific operations the LLM can execute
- 🔄 **Hot code reloading** - Safely update running actors without downtime

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Your Application                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │  AiActor A   │  │  AiActor B   │  │  AiActor C   │              │
│  │              │  │              │  │              │              │
│  │ • State      │  │ • State      │  │ • State      │              │
│  │ • Metadata   │  │ • Metadata   │  │ • Metadata   │              │
│  │ • Tools      │  │ • Tools      │  │ • Tools      │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                  │                  │                     │
│         └──────────────────┼──────────────────┘                     │
│                            │                                        │
└────────────────────────────┼────────────────────────────────────────┘
                             │
    ┌────────────────────────┼────────────────────────┐
    │                        │                        │
    ▼                        ▼                        ▼
┌─────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ LLM Client  │     │  ShadowRunner   │     │  CodeModifier   │
│             │     │                 │     │                 │
│ Multi-      │     │ • Shadow Mode   │     │ • Code Writing  │
│ Provider:   │     │ • Validation    │     │ • Compilation   │
│ • Anthropic │     │ • Stats         │     │ • Hot Reload    │
│ • OpenRouter│     │ • Promotion     │     │ • Backups       │
│ • Ollama    │     │                 │     │                 │
└─────────────┘     └─────────────────┘     └─────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│        OptimizationEvaluator          │
│                                       │
│  Tier Selection:                      │
│  • Deterministic (compile to code)    │
│  • Local LLM (Ollama/Granite)         │
│  • Accelerated (Cerebras/SambaNova)   │
│  • Full LLM (Claude Sonnet)           │
└───────────────────────────────────────┘
```

## Core Concepts

### AiActor

An AiActor is a GenServer with superpowers:

```elixir
defmodule MyApp.MyActor do
  use AiActors.AiActor

  @impl AiActors.AiActor
  def init(args) do
    {:ok, %{counter: 0}}
  end

  @impl AiActors.AiActor
  def development_metadata do
    %{
      purpose: "Track and analyze user interactions",
      design_decisions: [
        "Use in-memory state for speed",
        "Escalate complex queries to LLM"
      ],
      dependencies: ["UserService", "AnalyticsService"],
      version: "1.0.0"
    }
  end

  # Handle known messages explicitly - use handle_call_impl
  defp handle_call_impl({:increment, n}, _from, state) do
    {:reply, state.counter + n, %{state | counter: state.counter + n}}
  end

  # Unknown messages automatically escalate to LLM
  defp handle_call_impl(_unknown, _from, _state) do
    :escalate_to_llm
  end
end
```

> **Important**: Use `handle_call_impl/3` instead of `handle_call/3` to allow the framework to intercept messages and handle LLM escalation. See [WARP.md](WARP.md) for details.

### LLM Integration

AiActors can delegate to their associated LLM:

```elixir
# Explicit LLM query
{:ok, response} = MyActor.ask_llm(
  pid,
  "How many times has the counter been incremented by more than 10?",
  %{include_history: true}
)

# Automatic escalation for unhandled messages
# This message isn't explicitly handled, so it goes to LLM:
GenServer.call(pid, {:analyze_pattern, :last_hour})
```

### Self-Modification

Actors can request changes to their own code:

```elixir
MyActor.request_code_modification(pid, %{
  reason: "Need to add caching for performance",
  changes: "Add an ETS-backed cache for frequent queries"
})
```

The CodeModifier service will:
1. Use LLM to generate new code
2. Validate and compile it
3. Hot-reload the module
4. Notify the actor of success/failure

### Tools

Define tools that the LLM can call:

```elixir
@impl AiActors.AiActor
def available_tools do
  AiActors.AiActor.default_tools() ++ [
    %{
      name: "send_notification",
      description: "Send a notification to the user",
      input_schema: %{
        type: "object",
        properties: %{
          user_id: %{type: "string"},
          message: %{type: "string"}
        },
        required: ["user_id", "message"]
      }
    }
  ]
end

@impl AiActors.AiActor
def execute_tool("send_notification", %{"user_id" => uid, "message" => msg}, state) do
  # Execute the tool
  NotificationService.send(uid, msg)
  {:ok, %{sent: true}, state}
end
```

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:ai_actors, path: "./ai_actors"}
  ]
end
```

Set your API keys:

```bash
# Required: Anthropic Claude (primary LLM)
export ANTHROPIC_API_KEY="your-api-key"

# Optional: OpenRouter for accelerated inference (Cerebras, SambaNova)
export OPENROUTER_API_KEY="your-openrouter-key"

# Optional: Ollama for local models (zero-cost inference)
# Just ensure ollama is running: ollama serve
```

## Quick Start

### 1. Create an AiActor

```elixir
defmodule MyApp.TaskManager do
  use AiActors.AiActor

  def init(_args) do
    {:ok, %{tasks: [], next_id: 1}}
  end

  def development_metadata do
    %{
      purpose: "Manage tasks with natural language interface",
      version: "1.0.0"
    }
  end

  # Explicit handlers for known operations - use handle_call_impl
  defp handle_call_impl({:add_task, title}, _from, state) do
    task = %{id: state.next_id, title: title, done: false}
    new_state = %{
      state |
      tasks: state.tasks ++ [task],
      next_id: state.next_id + 1
    }
    {:reply, {:ok, task}, new_state}
  end

  # Let LLM handle natural language queries
  defp handle_call_impl(_msg, _from, _state) do
    :escalate_to_llm
  end
end
```

### 2. Start and Use

```elixir
# Start the actor
{:ok, pid} = MyApp.TaskManager.start_link([])

# Use explicit handlers
{:ok, task} = GenServer.call(pid, {:add_task, "Buy groceries"})

# Use LLM for natural language
{:ok, response} = MyApp.TaskManager.ask_llm(
  pid,
  "What tasks are still incomplete?"
)
```

## Examples

See the `lib/ai_actors/examples/` directory for complete examples:

- **CounterActor** - Simple counter with history tracking
- **TaskManagerActor** - Task management with custom tools
- **LearningCounterActor** - Self-learning counter that evolves over time

## Testing

Run the test suite:

```bash
mix test
```

Run specific test files:

```bash
mix test test/ai_actors/ai_actor_test.exs
```

## Claude Code Integration

AiActors includes a two-phase workflow for creating new components:

### Phase 1: Design

Claude Code creates high-level design documents with:
- Architecture overview
- Interface specifications
- State management approach
- Integration points

### Phase 2: Implementation

A specialized subagent implements the design:
- Creates concrete code
- Uses AiActor where appropriate
- Writes comprehensive tests

### Usage

```elixir
{:ok, result} = AiActors.ClaudeIntegration.create_component(
  name: "SessionManager",
  purpose: "Manage user sessions with auto-timeout",
  should_be_ai_actor: true,
  requirements: [
    "Track active sessions",
    "Auto-timeout after inactivity",
    "Send expiration notifications"
  ]
)
```

This generates:
- Design document in `docs/designs/`
- Module skeleton in `lib/ai_actors/components/`
- Test file in `test/ai_actors/components/`

## Self-Learning

AiActors can automatically learn from their interactions:

```elixir
defmodule MyApp.SmartActor do
  use AiActors.AiActor

  # Enable self-learning
  def enable_self_learning?, do: true

  def self_learning_config do
    %{
      review_interval_hours: 24,        # Daily analysis
      min_escalations_for_analysis: 10,
      pattern_threshold: 3
    }
  end

  # Start with minimal handlers - use handle_call_impl
  defp handle_call_impl(:known_op, _from, state) do
    {:reply, :ok, state}
  end

  # Unknown operations escalate to LLM
  defp handle_call_impl(_msg, _from, _state), do: :escalate_to_llm
end

# After enough escalations, the actor will:
# 1. Identify common patterns
# 2. Generate deterministic handlers
# 3. Validate handler performance
# 4. Become progressively faster and cheaper

{:ok, pid} = MyApp.SmartActor.start_link([])

# Monitor learning progress
stats = MyApp.SmartActor.get_learning_stats(pid)
# %{
#   escalation_rate: 0.25,  # 75% handled deterministically!
#   avg_response_time_ms: 50,  # Down from 1500ms
#   handler_success_rate: 0.98
# }
```

**Result**: 100-300x faster responses, 80%+ cost reduction

📚 **See [docs/SELF_LEARNING.md](docs/SELF_LEARNING.md) for complete guide**

## Configuration

Configure the LLM client in `config/config.exs`:

```elixir
config :ai_actors,
  max_tokens: 4096,
  temperature: 1.0,
  enable_code_modification: true

# Multi-provider LLM configuration
config :ai_actors, :llm_providers,
  anthropic: [
    api_key: {:system, "ANTHROPIC_API_KEY"}
    # Models: :sonnet, :haiku, :opus
  ],
  openrouter: [
    api_key: {:system, "OPENROUTER_API_KEY"}
    # Models: :cerebras_llama70b, :sambanova_llama405b, :groq_llama70b
  ],
  ollama: [
    base_url: "http://localhost:11434",
    models: [
      granite_micro: "granite3.1-dense:2b",
      granite_small: "granite3.1-dense:8b"
    ]
  ]

# Shadow mode configuration (for multi-tier optimization)
config :ai_actors, :shadow_config,
  min_shadow_executions: 50,      # Minimum runs before promotion
  min_match_rate: 0.98,           # 98% match required
  max_crash_rate: 0.01,           # Max 1% crash rate
  min_shadow_duration_hours: 24,  # Must run for 24+ hours
  shadow_timeout_ms: 5000         # Timeout for shadow handlers
```

## Safety & Best Practices

### Code Modification Safety

The CodeModifier includes safety features:
- Syntax validation before writing
- Automatic backups of previous versions
- Compilation verification before loading
- Rollback support on errors

### LLM Usage

- **Rate limiting**: Be mindful of API rate limits
- **Cost management**: LLM calls can be expensive - use explicit handlers for known operations
- **Testing**: Mock LLM responses in tests
- **Fallbacks**: Always have fallback behavior for LLM failures

### Development Context

Maintain clear development metadata:
- Document the actor's purpose
- Record key design decisions
- Track dependencies
- Version your actors

## Architecture Decisions

### Why GenServer?

GenServer provides the perfect foundation:
- ✅ State management
- ✅ Message passing
- ✅ Supervision trees
- ✅ Hot code reloading
- ✅ Distribution support

### Why LLM Integration?

LLMs enable:
- ✅ Natural language interfaces
- ✅ Intelligent fallback behavior
- ✅ Self-documentation
- ✅ Adaptive responses
- ✅ Code generation assistance

### Design Philosophy

1. **Explicit over implicit** - Known operations should have explicit handlers
2. **LLM as fallback** - Use LLM for truly unknown or complex queries
3. **Self-documenting** - Metadata is first-class
4. **Safe self-modification** - Multiple safety checks for code changes
5. **Tool-based interaction** - LLM uses well-defined tools, not arbitrary code execution

## API Reference

### AiActor Behavior

```elixir
@callback init(term()) :: {:ok, state} | {:stop, reason}
@callback development_metadata() :: map()
@callback available_tools() :: list(tool())
@callback execute_tool(String.t(), map(), state) ::
  {:ok, result, new_state} | {:error, reason}
```

### LLMClient

```elixir
@spec send_message(list(message()), keyword()) :: {:ok, response()} | {:error, term()}
@spec send_message_with_tools(list(message()), list(tool()), keyword(), function()) ::
  {:ok, response()} | {:error, term()}
@spec parse_structured_response(map()) :: {:ok, map()} | {:error, term()}
```

### CodeModifier

```elixir
@spec modify_code(module(), String.t(), map()) :: {:ok, reference()} | {:error, term()}
@spec get_module_source(module()) :: {:ok, String.t()} | {:error, term()}
@spec list_modifications() :: list(map())
```

## Roadmap

- [x] Multi-LLM provider support (Anthropic, OpenRouter, Ollama)
- [x] Multi-tier optimization (deterministic → local → accelerated → full)
- [x] Shadow mode for safe handler validation
- [ ] Distributed AiActor support
- [ ] Built-in observability and metrics
- [ ] Actor collaboration patterns
- [ ] Enhanced tool validation
- [ ] Conversation history persistence
- [ ] Visual actor state inspector
- [ ] Learning dashboards

## Contributing

Contributions welcome! Please ensure:
- Tests pass: `mix test`
- Code is formatted: `mix format`
- Documentation is updated

## License

MIT License - see LICENSE file for details

## Credits

Built with ❤️ using:
- Elixir & OTP
- Claude API (Anthropic)
- Req HTTP client
- Jason JSON library

---

**Note**: This is an experimental framework. Use in production with appropriate safeguards and monitoring.
