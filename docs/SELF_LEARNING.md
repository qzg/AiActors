#!/# Self-Learning AiActors

## Overview

AiActors can learn from their interactions and evolve to handle common patterns deterministically over time. This reduces costs, improves performance, and makes actors progressively more efficient.

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                   Self-Learning Cycle                    │
└─────────────────────────────────────────────────────────┘

1. TRACK
   ↓
   Every LLM escalation is logged:
   - Message that triggered escalation
   - LLM response
   - Execution time
   - Timestamp

2. ANALYZE
   ↓
   Periodic review identifies patterns:
   - Group similar messages
   - Find frequently occurring patterns
   - Generate handler recommendations

3. IMPLEMENT
   ↓
   Auto-generate deterministic handlers:
   - Create Elixir function code
   - Add tracking instrumentation
   - Integrate via CodeModifier

4. VALIDATE
   ↓
   Monitor new handler performance:
   - Track success rate
   - Measure execution time
   - Compare vs LLM escalation

5. ITERATE
   ↓
   Continuous improvement:
   - Refine handlers that need work
   - Add more handlers for new patterns
   - Remove ineffective handlers
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

### 2. SelfLearning Module

Orchestrates the learning workflow.

```elixir
# Start periodic learning
{:ok, timer} = AiActors.SelfLearning.start_learning(pid, MyActor)

# Perform immediate review
{:ok, result} = AiActors.SelfLearning.perform_review(MyActor)

# Generate learning report
report = AiActors.SelfLearning.generate_report(MyActor)

# Validate handlers
{:ok, validation} = AiActors.SelfLearning.validate_handlers(
  MyActor,
  implementations
)
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

### Escalation vs Handler

|   | LLM Escalation | Learned Handler | Improvement |
|---|----------------|-----------------|-------------|
| Latency | 1000-3000ms | 1-10ms | **100-300x faster** |
| Cost | $0.001-0.01 | $0 | **100% savings** |
| Reliability | Network dependent | Local | **More reliable** |

### Example: 1000 requests/day

**Without Learning:**
- All escalate to LLM
- Cost: $10/day
- Avg latency: 1500ms

**With Learning (after 1 week):**
- 80% handled deterministically
- Cost: $2/day (80% reduction)
- Avg latency: 350ms (77% reduction)

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

Planned features:

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
