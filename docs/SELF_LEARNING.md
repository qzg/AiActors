#!/# Self-Learning AiActors

## Overview

AiActors can learn from their interactions and evolve to handle common patterns deterministically over time. This reduces costs, improves performance, and makes actors progressively more efficient.

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│          Self-Learning with Shadow Mode                  │
└─────────────────────────────────────────────────────────┘

1. TRACK
   ↓
   Every LLM escalation is logged:
   - Message that triggered escalation
   - LLM response
   - Execution time
   - Timestamp

2. ANALYZE (OptimizationEvaluator)
   ↓
   Periodic review identifies patterns and optimal tier:
   - Group similar messages
   - Analyze response variance
   - Select optimization tier:
     • Deterministic (95%+ identical responses)
     • Local LLM (simple, low-token patterns)
     • Accelerated LLM (moderate complexity)
     • Keep Full LLM (complex reasoning)

3. SHADOW MODE (ShadowRunner)
   ↓
   Register shadow handlers for safe validation:
   - Run in parallel with primary handler
   - Crash-isolated (won't affect primary)
   - Compare results with primary response
   - Track statistics (match rate, crashes)

4. VALIDATE
   ↓
   Automatic promotion criteria:
   - 50+ shadow executions
   - 98%+ match rate with primary
   - <1% crash rate
   - 24+ hours of shadow runtime

5. PROMOTE
   ↓
   Hot-reload optimized handler:
   - CodeModifier compiles new code
   - Handler replaces LLM escalation
   - Continue monitoring for issues
```

## Key Components

### 1. EscalationTracker

Tracks all LLM usage and handler executions.

```elixir
# Log an escalation
AiActors.EscalationTracker.log_escalation(
  MyActor,
  self(),
  {:unknown_message, :data},
  :call,
  {:ok, %{"response" => "..."}},
  150  # execution time in ms
)

# Get escalation history
escalations = AiActors.EscalationTracker.get_escalations(MyActor)

# Get statistics
stats = AiActors.EscalationTracker.get_statistics(MyActor)

# Analyze patterns
{:ok, analysis} = AiActors.EscalationTracker.analyze_patterns(MyActor)
```

### 2. OptimizationEvaluator

Analyzes patterns and recommends optimization tiers.

```elixir
# Evaluate a specific pattern
result = AiActors.OptimizationEvaluator.evaluate_pattern(
  MyActor,
  {:multiply, :_number},  # normalized pattern
  escalation_history
)

case result do
  {:deterministic, code} ->
    # Pattern always produces same response - compile to code
    IO.puts("Generated handler: #{code}")

  {:local_llm, prompt_template, :granite_micro} ->
    # Use local Ollama for this pattern (zero cost)
    IO.puts("Use local LLM with prompt template")

  {:accelerated_llm, prompt_template, :cerebras_llama70b} ->
    # Use fast accelerated inference
    IO.puts("Use Cerebras for faster inference")

  :keep_current ->
    # Pattern requires full Claude reasoning
    IO.puts("Keep using Claude Sonnet")
end
```

### 3. ShadowRunner

Manages shadow handlers for safe validation before promotion.

```elixir
# Register a shadow handler
handler_spec = %{
  type: :deterministic,
  code: "def handle_call({:multiply, n}, _from, state) do...",
  created_at: DateTime.utc_now()
}

:ok = AiActors.ShadowRunner.register_shadow(MyActor, {:multiply, :_number}, handler_spec)

# Shadow handlers run automatically in parallel with primary
# Check statistics
{:ok, stats} = AiActors.ShadowRunner.get_shadow_stats(MyActor, {:multiply, :_number})
# %{
#   executions: 75,
#   matches: 74,
#   mismatches: 1,
#   crashes: 0,
#   match_rate: 0.9867,
#   crash_rate: 0.0,
#   first_execution_at: ~U[2025-01-15 10:00:00Z]
# }

# When criteria met, promote to primary
{:ok, ref} = AiActors.ShadowRunner.promote_shadow(MyActor, {:multiply, :_number})
```

### 4. SelfLearning Module

Orchestrates the learning workflow.

```elixir
# Start periodic learning
{:ok, timer} = AiActors.SelfLearning.start_learning(pid, MyActor)

# Perform immediate review (analyzes + registers shadows)
{:ok, result} = AiActors.SelfLearning.perform_review(MyActor)

# Generate learning report
report = AiActors.SelfLearning.generate_report(MyActor)

# Check and promote eligible shadows
{:ok, promotions} = AiActors.SelfLearning.check_promotions(MyActor)
```

### 3. Enhanced AiActor

Integrated tracking and learning capabilities.

```elixir
defmodule MyApp.SmartActor do
  use AiActors.AiActor

  # Enable self-learning
  @impl true
  def enable_self_learning?, do: true

  # Configure learning behavior
  @impl true
  def self_learning_config do
    %{
      review_interval_hours: 24,        # How often to analyze
      min_escalations_for_analysis: 10,  # Minimum data needed
      pattern_threshold: 3,              # Min occurrences = pattern
      validation_window_hours: 48        # How long to validate
    }
  end

  # Your handlers...
end
```

## Configuration Options

### Review Interval

How often to perform pattern analysis:

```elixir
review_interval_hours: 24  # Daily review
review_interval_hours: 4   # Every 4 hours (aggressive)
review_interval_hours: 168 # Weekly
```

### Min Escalations for Analysis

Minimum escalations before analysis:

```elixir
min_escalations_for_analysis: 5   # Analyze with limited data
min_escalations_for_analysis: 10  # Default
min_escalations_for_analysis: 50  # Wait for more data
```

### Pattern Threshold

How many occurrences make a pattern:

```elixir
pattern_threshold: 2  # Just 2 occurrences (aggressive)
pattern_threshold: 3  # Default
pattern_threshold: 5  # Only clear patterns
```

### Validation Window

How long to monitor new handlers:

```elixir
validation_window_hours: 24  # Quick validation
validation_window_hours: 48  # Default
validation_window_hours: 168 # Full week
```

## Usage Example

### Step 1: Create Self-Learning Actor

```elixir
defmodule MyApp.CustomerSupportBot do
  use AiActors.AiActor

  @impl true
  def init(_) do
    {:ok, %{conversations: [], unhandled_queries: []}}
  end

  @impl true
  def enable_self_learning?, do: true

  @impl true
  def self_learning_config do
    %{
      review_interval_hours: 6,
      min_escalations_for_analysis: 8,
      pattern_threshold: 3,
      validation_window_hours: 24
    }
  end

  @impl true
  def development_metadata do
    %{
      purpose: "Customer support chatbot with self-learning",
      design_decisions: [
        "Start with minimal handlers",
        "Learn common questions over time",
        "Provide fast responses for known queries"
      ],
      version: "1.0.0"
    }
  end

  # Initial handlers (just a few)
  def handle_call({:greeting}, _from, state) do
    {:reply, "Hello! How can I help?", state}
  end

  # Everything else escalates (initially)
  def handle_call(_msg, _from, _state) do
    :escalate_to_llm
  end
end
```

### Step 2: Start and Use

```elixir
# Start the bot
{:ok, bot} = MyApp.CustomerSupportBot.start_link([])

# Users ask questions (initially escalate to LLM)
GenServer.call(bot, {:ask, "What are your hours?"})
GenServer.call(bot, {:ask, "How do I reset my password?"})
GenServer.call(bot, {:ask, "What are your hours?"})  # Asked again
GenServer.call(bot, {:ask, "What are your hours?"})  # And again
```

### Step 3: Monitor Learning

```elixir
# Check statistics
stats = MyApp.CustomerSupportBot.get_learning_stats(bot)

IO.inspect(stats.statistics)
# %{
#   total_escalations: 15,
#   total_handler_executions: 5,
#   avg_escalation_time_ms: 1500,
#   avg_handler_time_ms: 5,
#   handler_success_rate: 1.0
# }

IO.inspect(stats.report)
# %{
#   learning_status: :progressing_well,
#   performance_metrics: %{
#     escalation_rate: 0.75,  # 75% still escalate
#     handler_efficiency: 1.0,
#     avg_response_time_ms: 1127
#   }
# }
```

### Step 4: Trigger Review (Manual)

```elixir
# Force a learning review
{:ok, result} = MyApp.CustomerSupportBot.trigger_review(bot)

IO.inspect(result.analysis.patterns_found)
# [
#   %{
#     pattern: {:ask, :_string},
#     occurrences: 8,
#     avg_execution_time_ms: 1450,
#     examples: [...]
#   }
# ]

IO.inspect(result.analysis.recommendations)
# [
#   %{
#     "pattern" => "asking about hours",
#     "handler_code" => "def handle_call({:ask, \"What are your hours?\"}, ...",
#     "rationale" => "Frequently asked question, deterministic answer",
#     "estimated_speedup" => "300x faster (5ms vs 1500ms)"
#   }
# ]
```

### Step 5: Automatic Implementation

If recommendations are approved, they're automatically implemented:

```elixir
# Code is modified and reloaded
# New handlers are now active

# Next query uses new handler (fast!)
GenServer.call(bot, {:ask, "What are your hours?"})  # ~5ms instead of ~1500ms
```

### Step 6: Validation

After the validation window:

```elixir
# System automatically validates new handlers
# Checks success rate and performance

# If validation passes: Handler stays
# If validation fails: Handler may be removed/refined
```

## Monitoring and Observability

### Get Escalation History

```elixir
# All escalations
escalations = AiActors.EscalationTracker.get_escalations(MyActor)

# Limited results
recent = AiActors.EscalationTracker.get_escalations(MyActor, limit: 10)

# Since timestamp
cutoff = DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second)
today = AiActors.EscalationTracker.get_escalations(MyActor, since: cutoff)
```

### Get Handler Executions

```elixir
executions = AiActors.EscalationTracker.get_handler_executions(MyActor)
```

### Analyze Performance

```elixir
report = AiActors.SelfLearning.generate_report(MyActor)

# Escalation rate (lower is better)
escalation_rate = report.performance_metrics.escalation_rate
# 0.0 = all handled deterministically
# 1.0 = everything escalates

# Learning status
case report.learning_status do
  :learning_phase -> "Collecting data"
  :needs_more_handlers -> "Patterns identified, needs handlers"
  :progressing_well -> "Learning and improving"
  :highly_optimized -> "Most queries handled deterministically"
end
```

## Best Practices

### 1. Start Minimal

Begin with just a few explicit handlers:

```elixir
# ✅ Good: Minimal starting point
def handle_call(:ping, _from, state), do: {:reply, :pong, state}
def handle_call(_msg, _from, _state), do: :escalate_to_llm

# ❌ Bad: Too many initial handlers (nothing to learn)
def handle_call(:ping, ...), do: ...
def handle_call({:get, _}, ...), do: ...
def handle_call({:set, _, _}, ...), do: ...
# ... 50 more handlers
```

### 2. Configure Based on Traffic

High traffic → faster learning:

```elixir
# High traffic service (100+ msgs/hour)
review_interval_hours: 4
min_escalations_for_analysis: 20

# Low traffic service (10 msgs/hour)
review_interval_hours: 24
min_escalations_for_analysis: 5
```

### 3. Monitor Validation Results

Check handler health:

```elixir
{:ok, validation} = AiActors.SelfLearning.validate_handlers(MyActor, impls)

Enum.each(validation.validations, fn v ->
  case v.status do
    :excellent -> Logger.info("✓ #{v.pattern}: #{v.success_rate * 100}%")
    :needs_improvement -> Logger.warning("⚠ #{v.pattern}: needs review")
  end
end)
```

### 4. Review Recommendations

Before auto-implementing, review:

```elixir
{:ok, analysis} = AiActors.EscalationTracker.analyze_patterns(MyActor)

# Inspect recommendations
Enum.each(analysis.recommendations, fn rec ->
  IO.puts "Pattern: #{rec["pattern"]}"
  IO.puts "Code:\n#{rec["handler_code"]}"
  IO.puts "Rationale: #{rec["rationale"]}"
  IO.puts "---"
end)

# Then implement
{:ok, impls} = AiActors.SelfLearning.implement_recommendations(MyActor, analysis)
```

### 5. Track Costs

Monitor LLM cost savings:

```elixir
stats = AiActors.EscalationTracker.get_statistics(MyActor)

llm_calls = stats.total_escalations
handler_calls = stats.total_handler_executions

# Assuming $0.01 per LLM call
cost_without_learning = (llm_calls + handler_calls) * 0.01
cost_with_learning = llm_calls * 0.01
savings = cost_without_learning - cost_with_learning

IO.puts "Savings: $#{savings}"
```

## Performance Impact

### Multi-Tier Performance Comparison

| Tier | Latency | Cost/Request | Use Case |
|------|---------|--------------|----------|
| Deterministic | ~1ms | $0 | Identical responses |
| Local LLM (Ollama) | ~50-200ms | $0 | Simple patterns |
| Accelerated (Cerebras) | ~100-500ms | ~$0.001 | Moderate complexity |
| Full LLM (Claude) | 1-5s | ~$0.01 | Complex reasoning |

### Example: 1000 requests/day

**Without Optimization:**
- All escalate to full LLM
- Cost: $10/day
- Avg latency: 1500ms

**With Multi-Tier Optimization (after 1 week):**
- 40% deterministic handlers (~1ms, $0)
- 30% local LLM (~100ms, $0)
- 20% accelerated (~300ms, ~$2/day)
- 10% full LLM (~1500ms, ~$1/day)
- **Total cost: $3/day (70% reduction)**
- **Avg latency: ~200ms (87% reduction)**

## Troubleshooting

### Not Learning Fast Enough

```elixir
# Check if enough data
stats = AiActors.EscalationTracker.get_statistics(MyActor)

if stats.total_escalations < 10 do
  IO.puts "Need more data. Current: #{stats.total_escalations}"
end

# Reduce thresholds
def self_learning_config do
  %{
    min_escalations_for_analysis: 5,  # Lower threshold
    pattern_threshold: 2               # More aggressive
  }
end
```

### Handlers Failing Validation

```elixir
# Check validation results
{:ok, validation} = AiActors.SelfLearning.validate_handlers(MyActor, impls)

failing = Enum.filter(validation.validations, &(&1.status == :needs_improvement))

Enum.each(failing, fn f ->
  IO.puts "Failed: #{f.pattern}"
  IO.puts "Success rate: #{f.success_rate}"
  IO.puts "Recommendation: #{f.recommendation}"
end)

# May need to refine patterns or revert to LLM
```

### Too Many Patterns

```elixir
# Increase pattern threshold
def self_learning_config do
  %{
    pattern_threshold: 5  # Require 5+ occurrences
  }
end
```

## Advanced Usage

### Custom Pattern Analysis

Extend pattern detection:

```elixir
defmodule MyApp.CustomPatternAnalyzer do
  def analyze_custom_patterns(escalations) do
    # Your custom analysis logic
    # Group by semantic similarity, etc.
  end
end
```

### Manual Handler Creation

Instead of auto-generation:

```elixir
# Get recommendations
{:ok, analysis} = AiActors.EscalationTracker.analyze_patterns(MyActor)

# Manually write handlers based on recommendations
# Then add to your module
```

### A/B Testing Handlers

Compare LLM vs learned handler:

```elixir
def handle_call(msg, from, state) do
  if :rand.uniform() < 0.1 do
    # 10% still use LLM (for comparison)
    :escalate_to_llm
  else
    # 90% use learned handler
    handle_with_learned_handler(msg, from, state)
  end
end
```

## Future Enhancements

Completed:

- [x] Multi-tier optimization (deterministic/local/accelerated/full)
- [x] Shadow mode for safe validation
- [x] Multi-provider LLM support
- [x] Automatic promotion criteria

Planned:

- [ ] Semantic pattern grouping (via embeddings)
- [ ] Multi-actor learning (share patterns across actors)
- [ ] Confidence scores for handlers
- [ ] Automatic A/B testing
- [ ] Learning dashboards
- [ ] Handler quality metrics
- [ ] Rollback mechanisms

## See Also

- [Architecture Documentation](ARCHITECTURE.md)
- [Examples](EXAMPLES.md)
- [API Reference](../README.md)
