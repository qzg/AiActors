# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

AiActors is an experimental Elixir framework that extends OTP GenServers with Large Language Model (LLM) capabilities. The framework enables actors to intelligently handle unknown messages, self-modify their code, and learn from interactions over time.

**Core Innovation**: Combines Elixir's battle-tested OTP patterns with LLM intelligence to create actors that can fall back to AI reasoning when explicit handlers don't exist.

## Essential Commands

### Setup
```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile
```

### Testing
```bash
# Run all tests
mix test

# Run specific test file
mix test test/ai_actors/ai_actor_test.exs

# Run with coverage (if configured)
MIX_ENV=test mix test --cover

# Run tests with specific tags
mix test --only integration
```

### Code Quality
```bash
# Format code
mix format

# Check code formatting
mix format --check-formatted

# Run static analysis with Credo
mix credo

# Run Dialyzer for type checking
mix dialyzer
```

### Development
```bash
# Start interactive shell with project loaded
iex -S mix

# Compile and watch for changes (if using mix_test.watch)
mix test.watch

# Generate documentation
mix docs
```

## Environment Requirements

**LLM Provider API Keys**:
```bash
# Required for Claude (Anthropic) - primary LLM
export ANTHROPIC_API_KEY="your-api-key-here"

# Optional: For accelerated inference via OpenRouter (Cerebras, SambaNova)
export OPENROUTER_API_KEY="your-openrouter-key"

# Optional: For local models via Ollama (Granite, Llama)
# Just ensure ollama is running: `ollama serve`
```

Without ANTHROPIC_API_KEY, all LLM interactions will fail.

## Architecture Overview

### Three-Layer Design

1. **OTP Foundation** - Standard GenServer patterns for state management and supervision
2. **AiActor Enhancement** - Wraps GenServer with AI capabilities via macro injection
3. **Infrastructure Services** - LLMClient, CodeModifier, EscalationTracker, and SelfLearning modules

### Key Components

- **`AiActors.AiActor`** (`lib/ai_actors/ai_actor.ex`)
  - Macro that wraps GenServer to add AI capabilities
  - Handles message escalation via returning `:escalate_to_llm` from handle_call/cast
  - Maintains both user state and AI infrastructure state transparently
  - Provides `ask_llm/3`, `request_code_modification/2`, and learning methods

- **`AiActors.LLMClient`** (`lib/ai_actors/llm_client.ex`)
  - Multi-provider LLM integration (Anthropic, OpenRouter, Ollama)
  - Handles tool/function calling with automatic loop until completion
  - Default provider: Anthropic (Claude Sonnet)
  - Auto-detects provider from model alias
  - Uses Claude's native structured outputs API (beta) for guaranteed JSON schema compliance

- **`AiActors.LLMProvider`** (`lib/ai_actors/llm_provider.ex`)
  - Provider abstraction behaviour for LLM backends
  - Built-in providers:
    - `Anthropic` - Claude Sonnet/Haiku/Opus via direct API
    - `OpenRouter` - Cerebras, SambaNova, Groq for accelerated inference
    - `Ollama` - Local models like Granite, Llama for zero-cost inference

- **`AiActors.ShadowRunner`** (`lib/ai_actors/shadow_runner.ex`)
  - Manages shadow handler execution for safe optimization validation
  - Runs candidate handlers in parallel with primary (crash-isolated)
  - Compares results and tracks statistics in ETS
  - Handles promotion when criteria are met

- **`AiActors.OptimizationEvaluator`** (`lib/ai_actors/optimization_evaluator.ex`)
  - Analyzes escalation patterns to determine optimal handling tier
  - Four optimization tiers: Deterministic → Local LLM → Accelerated → Full
  - Tests simpler models against historical examples before recommending

- **`AiActors.CodeModifier`** (`lib/ai_actors/code_modifier.ex`)
  - Performs hot code reloading of actor modules
  - Safety features: syntax validation, automatic backups, compilation verification
  - Asynchronous modification with notification via message passing
  - Backup directory created in project root

- **`AiActors.EscalationTracker`** (`lib/ai_actors/escalation_tracker.ex`)
  - Logs all LLM escalations and handler executions
  - Tracks execution times for performance analysis
  - Provides pattern analysis for self-learning recommendations
  - In-memory storage (last 10,000 entries per type)

- **`AiActors.SelfLearning`** (`lib/ai_actors/self_learning.ex`)
  - Periodic pattern analysis to identify common LLM escalations
  - Integrates with OptimizationEvaluator for multi-tier recommendations
  - Registers shadow handlers for safe validation before promotion
  - Uses CodeModifier to implement promoted handlers automatically

### Message Flow Patterns

**Explicit Handler (Fast Path)**:
1. Message sent via GenServer.call/cast
2. Pattern matches explicit handler in module
3. Handler executes deterministically (~microseconds)
4. No LLM cost or latency

**LLM Escalation (Intelligent Fallback)**:
1. Message sent via GenServer.call/cast
2. No explicit handler matches, returns `:escalate_to_llm`
3. Framework builds context: state, metadata, tools, conversation history
4. LLMClient sends request to Claude API (~1-5 seconds)
5. If tool use required, executes tools and continues loop
6. Final response returned to caller
7. Escalation logged to EscalationTracker

**Self-Learning Cycle (with Shadow Mode)**:
1. Actor configured with `enable_self_learning?: true`
2. All escalations logged with normalized message patterns
3. Periodic review (default: every 24 hours) analyzes patterns
4. OptimizationEvaluator determines optimal tier for each pattern:
   - **Deterministic** - Identical responses → compile to code
   - **Local LLM** - Simple patterns → use Granite/Ollama (~0 cost)
   - **Accelerated LLM** - Moderate complexity → use Cerebras/OpenRouter
   - **Full LLM** - Complex reasoning → keep using Claude Sonnet
5. Shadow handlers registered to run in parallel with primary
6. Shadow results compared against primary in production traffic
7. After meeting criteria (50+ executions, 98% match, 24h), shadow promoted
8. CodeModifier validates, compiles, and hot-reloads promoted handler

**Shadow Mode Benefits**:
- **Crash Isolation** - Shadow handlers run under separate supervisor
- **Safe Validation** - Real traffic validates handlers before promotion
- **Automatic Rollback** - Poor-performing shadows are discarded
- **Gradual Optimization** - Progressive cost reduction over time

## Development Patterns

### Important: Use _impl Functions, Not GenServer Callbacks

**Critical**: When implementing AiActors, you must use private `*_impl` functions instead of the standard GenServer callbacks.

The framework wraps your state and provides its own callbacks that:
- Handle internal framework messages (`:__ai_actor_*`)
- Wrap/unwrap state automatically
- Intercept `:escalate_to_llm` returns and forward to LLM

If you override the GenServer callbacks directly, you'll break framework features.

**Use these patterns:**

```elixir
# ❌ WRONG - Don't override GenServer callbacks:
def init(args), do: {:ok, %{counter: 0}}
def handle_call({:increment, n}, _from, state), do: {:reply, n, state}

# ✅ CORRECT - Use _impl private functions:
defp init_impl(args), do: {:ok, %{counter: 0}}
defp handle_call_impl({:increment, n}, _from, state), do: {:reply, n, state}
defp handle_cast_impl(msg, state), do: {:noreply, state}
defp handle_info_impl(msg, state), do: {:noreply, state}
```

**Note**: You must define ALL four `*_impl` functions in your module.

### Creating a New AiActor

```elixir
defmodule MyApp.MyActor do
  use AiActors.AiActor

  # Initialize state (use init_impl, not init)
  defp init_impl(_args) do
    {:ok, %{counter: 0, data: []}}
  end

  @impl AiActors.AiActor
  def development_metadata do
    %{
      purpose: "Clear description of what this actor does",
      design_decisions: [
        "Why certain choices were made",
        "Trade-offs considered"
      ],
      dependencies: ["OtherService", "AnotherActor"],
      version: "1.0.0"
    }
  end

  # Explicit handlers for known operations
  defp handle_call_impl({:known_operation, arg}, _from, state) do
    # Fast, deterministic handling
    {:reply, result, new_state}
  end

  # Unknown messages escalate to LLM
  defp handle_call_impl(_unknown, _from, _state) do
    :escalate_to_llm
  end

  # Required: handle_cast_impl and handle_info_impl
  defp handle_cast_impl(_msg, state), do: {:noreply, state}
  defp handle_info_impl(_msg, state), do: {:noreply, state}
end
```

### Adding Custom Tools for LLM

Tools define actions the LLM can take:

```elixir
@impl AiActors.AiActor
def available_tools do
  AiActors.AiActor.default_tools() ++ [
    %{
      name: "custom_action",
      description: "What this action does",
      input_schema: %{
        type: "object",
        properties: %{
          param: %{type: "string", description: "Parameter description"}
        },
        required: ["param"]
      }
    }
  ]
end

@impl AiActors.AiActor
def execute_tool("custom_action", %{"param" => value}, state) do
  # Perform the action
  result = do_something(value, state)
  new_state = update_state(state)
  {:ok, result, new_state}
end
```

### Enabling Self-Learning

```elixir
@impl AiActors.AiActor
def enable_self_learning?, do: true

@impl AiActors.AiActor
def self_learning_config do
  %{
    review_interval_hours: 24,          # How often to analyze patterns
    min_escalations_for_analysis: 10,  # Minimum data before analysis
    pattern_threshold: 3,               # Times pattern must occur to trigger handler
    validation_window_hours: 48        # How long to validate new handlers
  }
end
```

## Testing Strategy

### Unit Tests (No LLM)
Test explicit handlers and logic without LLM calls:
```elixir
test "explicit handler works" do
  {:ok, pid} = MyActor.start_link([])
  assert {:ok, result} = GenServer.call(pid, {:known_operation, arg})
end
```

### Integration Tests (Mocked LLM)
Mock LLMClient responses to test escalation flow without API costs.

### E2E Tests (Real LLM)
Use `@tag :integration` for tests that call real Claude API - run sparingly due to cost and latency.

## Configuration

Located in `config/config.exs` and environment-specific files:

```elixir
config :ai_actors,
  max_tokens: 4096,                          # Max response length
  temperature: 1.0,                          # Sampling temperature
  enable_code_modification: true,            # Allow hot code reloading
  backup_retention_days: 30                  # Keep backups for 30 days

# Multi-provider LLM configuration
config :ai_actors, :llm_providers,
  anthropic: [
    api_key: {:system, "ANTHROPIC_API_KEY"},
    # Available models: :sonnet, :haiku, :opus
  ],
  openrouter: [
    api_key: {:system, "OPENROUTER_API_KEY"},
    # Available models: :cerebras_llama70b, :sambanova_llama405b, :groq_llama70b
  ],
  ollama: [
    base_url: "http://192.168.9.129:11434",
    models: [
      granite_micro: "granite4:small-h",
      granite_small: "granite4:small-h"
    ]
  ]

# Shadow mode configuration
config :ai_actors, :shadow_config,
  min_shadow_executions: 50,       # Minimum executions before promotion
  min_match_rate: 0.98,            # 98% match rate required
  max_crash_rate: 0.01,            # Max 1% crash rate allowed
  min_shadow_duration_hours: 24,   # Must run for at least 24 hours
  shadow_timeout_ms: 5000          # Timeout for shadow handler execution
```

## Important Constraints

### State Management
- **User state** is what you work with in handlers (transparent)
- **AI state** is managed by framework (llm_messages, metadata, tools, etc.)
- Never directly manipulate AI state - use provided callbacks and methods

### Code Modification Safety
- All modifications go through validation: syntax check → backup → compile → load
- Backups stored with timestamp in backup directory
- Compilation errors prevent code from being loaded (rollback to previous version)
- Always test code modifications in development before production

### LLM Considerations
- **Cost**: Each escalation costs money (tokens used)
- **Latency**: LLM calls take 1-5 seconds vs microseconds for explicit handlers
- **Rate Limits**: Anthropic API has rate limits - design for graceful degradation
- **Best Practice**: Use explicit handlers for known patterns, LLM for truly unknown/complex cases

### Structured Outputs API
The LLMClient uses Claude's native structured outputs API (public beta) for guaranteed JSON schema compliance:

- **Beta Header**: `structured-outputs-2025-11-13` - automatically added when `structured_output` option is used
- **Format**: Uses `output_format: { type: "json_schema", schema: <schema> }` parameter
- **Constrained Decoding**: Guarantees responses match the schema exactly - no more JSON.parse() errors
- **Schema Requirements**:
  - All object types should have `additionalProperties: false` (auto-added by framework)
  - Empty schemas (`%{}`) are not supported - always specify concrete types
  - Supported models: Claude Sonnet 4.5, Claude Opus 4.1, Claude Opus 4.5, Claude Haiku 4.5
- **Edge Cases**: `stop_reason: "refusal"` or `stop_reason: "max_tokens"` may result in non-compliant output

### Tool Execution
- Tools must have valid JSON schemas
- All inputs validated against schema
- Tool execution is synchronous within LLM loop
- Long-running tools can block message handling - consider async patterns
- Tools can modify actor state (return new_state in tuple)

## Examples

See `lib/ai_actors/examples/` for complete working examples:
- **`counter_actor.ex`** - Simple counter with history and LLM queries
- **`task_manager_actor.ex`** - Task management with custom tools
- **`learning_counter_actor.ex`** - Self-learning counter that adds handlers over time

## Debugging

### Check Escalation History
```elixir
# In iex -S mix
escalations = AiActors.EscalationTracker.get_escalations(MyActor)
IO.inspect(escalations)
```

### View Learning Statistics
```elixir
{:ok, pid} = MyActor.start_link([])
stats = MyActor.get_learning_stats(pid)
# Returns: %{escalation_rate: 0.25, avg_response_time_ms: 50, handler_success_rate: 0.98}
```

### Trigger Manual Review
```elixir
MyActor.trigger_review(pid)  # Force self-learning analysis
```

### Check Metadata
```elixir
metadata = MyActor.get_metadata(pid)
```

## Common Pitfalls

1. **Forgetting ANTHROPIC_API_KEY** - All LLM calls will fail silently or with errors
2. **Returning wrong tuple from handlers** - Must return proper GenServer response tuples
3. **Not providing development_metadata** - LLM won't have context about actor purpose
4. **Blocking tool execution** - Long-running tools block the actor process
5. **Over-relying on LLM** - Identify common patterns early and add explicit handlers
6. **Ignoring escalation logs** - Review EscalationTracker data to find optimization opportunities

## Related Documentation

- **Architecture Deep Dive**: `docs/ARCHITECTURE.md` - Detailed component design and rationale
- **Self-Learning Guide**: `docs/SELF_LEARNING.md` - Complete guide to actor learning capabilities
- **Examples**: `docs/EXAMPLES.md` - Additional usage examples and patterns
- **README**: `README.md` - High-level overview and quick start

## Development Philosophy

The framework follows these principles:

1. **Explicit over Implicit** - Known operations use explicit handlers, not LLM
2. **LLM as Fallback** - AI handles truly unknown or complex scenarios
3. **Self-Documenting** - Metadata is first-class, helps LLM understand context
4. **Safe Self-Modification** - Multiple checks prevent dangerous code changes
5. **Tool-Based Interaction** - No arbitrary code execution, only validated tools
6. **Progressive Enhancement** - Actors become faster/cheaper over time via learning
