# AiActors Architecture

## System Overview

AiActors is built on three core principles:

1. **OTP Foundation** - Leverage battle-tested GenServer patterns
2. **LLM Enhancement** - Add intelligence where traditional code falls short
3. **Safe Self-Modification** - Enable evolution while maintaining safety

## Component Architecture

### Layer 1: Core OTP

```
┌─────────────────────────────────────┐
│     Erlang/OTP Foundation           │
│  • GenServer                        │
│  • Supervision Trees                │
│  • Hot Code Reloading               │
│  • Message Passing                  │
└─────────────────────────────────────┘
```

Everything builds on OTP's solid foundation.

### Layer 2: AiActor Enhancement

```
┌─────────────────────────────────────┐
│       AiActor Behavior              │
│                                     │
│  ┌──────────────────────────────┐  │
│  │   User State                 │  │
│  │   • Your GenServer state     │  │
│  └──────────────────────────────┘  │
│                                     │
│  ┌──────────────────────────────┐  │
│  │   AI Extensions              │  │
│  │   • Development metadata     │  │
│  │   • LLM conversation history │  │
│  │   • Available tools          │  │
│  │   • Pending modifications    │  │
│  └──────────────────────────────┘  │
└─────────────────────────────────────┘
```

AiActor wraps your state with AI capabilities.

### Layer 3: Infrastructure Services

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  LLMClient   │    │ LLMProvider  │    │ShadowRunner  │    │CodeModifier  │
│              │    │              │    │              │    │              │
│ • Multi-prov │    │ • Anthropic  │    │ • Shadow     │    │ • Validation │
│ • Tools      │    │ • OpenRouter │    │   handlers   │    │ • Backup     │
│ • Structured │    │ • Ollama     │    │ • Stats      │    │ • Compile    │
│   output     │    │              │    │ • Promotion  │    │ • Reload     │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
                           │
                           ▼
                    ┌──────────────────┐
                    │ Optimization     │
                    │ Evaluator        │
                    │                  │
                    │ • Pattern        │
                    │   analysis       │
                    │ • Tier selection │
                    │ • Code gen       │
                    └──────────────────┘
```

Supporting services provide core functionality.

## Message Flow

### Standard Message (Known)

```
User
 │
 │ GenServer.call(pid, {:increment, 5})
 ▼
┌────────────────┐
│    AiActor     │
│                │
│  handle_call   │───→ Explicit handler
│  {:increment,n}│     executes
│                │
│  {:reply, ...} │
└────────────────┘
```

Fast path - no LLM involved.

### Unknown Message (Escalated)

```
User
 │
 │ GenServer.call(pid, {:analyze_trends})
 ▼
┌────────────────┐
│    AiActor     │
│                │
│  handle_call   │───→ Returns :escalate_to_llm
│  _unknown      │
└────────┬───────┘
         │
         │ Build prompt with context
         ▼
┌────────────────┐
│   LLMClient    │───→ Claude API
│                │◄─── Response
└────────┬───────┘
         │
         │ Parse & validate
         ▼
┌────────────────┐
│    AiActor     │
│                │
│  Reply to user │
└────────────────┘
```

Intelligent fallback for unknown operations.

### Tool Execution Flow

```
User asks LLM to perform action
 │
 ▼
LLMClient sends message with tools
 │
 ▼
Claude decides to use tool
 │
 ▼
LLMClient receives tool_use response
 │
 ▼
Execute tool via execute_tool/3
 │
 ▼
Return result to Claude
 │
 ▼
Claude generates final response
 │
 ▼
Return to user
```

Tools enable LLM to interact with system state.

## Code Modification Flow

```
Actor needs code change
 │
 ▼
Request modification
 │
 ▼
┌────────────────┐
│  CodeModifier  │
└────────┬───────┘
         │
         ├─→ Validate syntax
         │
         ├─→ Backup current version
         │
         ├─→ Write new code
         │
         ├─→ Compile
         │
         ├─→ Load (hot swap)
         │
         └─→ Notify actor
```

Safe, incremental code evolution.

## State Management

### AiActor State Structure

```elixir
%{
  # Your application state (transparent to you)
  user_state: %{
    counter: 42,
    tasks: [...]
  },

  # AI infrastructure (managed by framework)
  llm_messages: [
    %{role: "user", content: "..."},
    %{role: "assistant", content: "..."}
  ],

  development_metadata: %{
    purpose: "...",
    design_decisions: [...],
    version: "1.0.0"
  },

  conversation_history: [...],
  available_tools: [...],
  pending_modifications: %{
    ref1 => %{reason: "...", requested_at: ~U[...]}
  }
}
```

### State Isolation

User code only sees `user_state`:

```elixir
def handle_call(:get_count, _from, state) do
  # `state` here is user_state only
  {:reply, state.counter, state}
end
```

Framework manages AI state transparently.

## Tool System

### Tool Definition

```elixir
%{
  name: "create_task",
  description: "Create a new task",
  input_schema: %{
    type: "object",
    properties: %{
      title: %{type: "string"}
    },
    required: ["title"]
  }
}
```

### Tool Execution

```elixir
def execute_tool("create_task", %{"title" => title}, state) do
  task = %{id: next_id(state), title: title}
  new_state = add_task(state, task)
  {:ok, task, new_state}
end
```

### Tool Call Chain

1. LLM receives tools in prompt
2. LLM decides to use tool
3. Framework calls execute_tool/3
4. Result sent back to LLM
5. LLM continues reasoning
6. Final response to user

## Design Decisions

### Why Wrap GenServer?

**Alternative**: Require users to manually integrate LLM

**Chosen**: Use macro to wrap GenServer behavior

**Rationale**:
- Seamless developer experience
- Maintains GenServer patterns
- No boilerplate
- Easy to adopt incrementally

### Why Escalation Pattern?

**Alternative**: Route all messages through LLM

**Chosen**: Explicit handlers + LLM fallback

**Rationale**:
- Performance (known messages are fast)
- Cost (fewer LLM calls)
- Predictability (explicit behavior for common cases)
- Intelligence (LLM handles edge cases)

### Why Tool-Based Interaction?

**Alternative**: Let LLM generate arbitrary code

**Chosen**: Pre-defined tools with schemas

**Rationale**:
- **Safety**: No arbitrary code execution
- **Validation**: Strong typing via schemas
- **Observability**: All actions are logged tools
- **Testing**: Tools can be tested independently

### Why Async Code Modification?

**Alternative**: Synchronous modification

**Chosen**: Async with notification

**Rationale**:
- Non-blocking (actor continues running)
- Safe (compilation happens out-of-band)
- Recoverable (can rollback on failure)
- Traceable (modifications are tracked)

## Security Considerations

### API Key Management

- Never commit API keys
- Use environment variables
- Rotate keys regularly
- Monitor usage

### Code Modification Safety

- Syntax validation before writing
- Compilation before loading
- Backup before modification
- Version tracking
- Rollback capability

### LLM Input Validation

- Sanitize user input
- Limit message length
- Rate limiting
- Cost monitoring

### Tool Execution Safety

- Validate all inputs against schema
- Check authorization
- Log all executions
- Timeout protection

## Performance Characteristics

### Known Messages (Explicit Handlers)

- **Latency**: Microseconds (standard GenServer)
- **Throughput**: Thousands per second
- **Cost**: Zero

### Multi-Tier Optimization

The system automatically selects the optimal tier for each pattern:

| Tier | Latency | Cost | Use Case |
|------|---------|------|----------|
| Deterministic | ~1ms | $0 | Identical responses (95%+ same) |
| Local LLM (Ollama) | ~50-200ms | $0 | Simple patterns, low tokens |
| Accelerated (Cerebras) | ~100-500ms | ~$0.001 | Moderate complexity |
| Full LLM (Claude) | 1-5s | ~$0.01 | Complex reasoning |

### Optimization Strategies

1. **Multi-tier optimization** - Automatically downgrade to cheaper/faster tiers
2. **Shadow mode validation** - Test handlers safely before promotion
3. **Use explicit handlers** for known operations
4. **Pattern analysis** - Identify common escalations
5. **Monitor and optimize** token usage

## Scaling Considerations

### Horizontal Scaling

- AiActors are regular processes
- Distribute across nodes normally
- Use process registries (pg, Horde)
- Consider API rate limits

### Vertical Scaling

- Each actor is independent
- Supervision tree handles failures
- Hot code reload enables updates
- Monitor memory per actor

## Testing Strategy

### Unit Tests

Test without LLM:

```elixir
test "explicit handlers work" do
  {:ok, pid} = MyActor.start_link([])
  assert 5 == GenServer.call(pid, {:increment, 5})
end
```

### Integration Tests (Mocked)

Mock LLM responses:

```elixir
test "LLM escalation" do
  # Mock LLMClient
  assert {:ok, response} = MyActor.ask_llm(pid, "query")
end
```

### E2E Tests

Real LLM (sparingly):

```elixir
@tag :integration
test "real LLM interaction" do
  # Actual API call
end
```

## Future Enhancements

### Completed Features

- [x] Multi-provider LLM support (Anthropic, OpenRouter, Ollama)
- [x] Multi-tier optimization (deterministic → local → accelerated → full)
- [x] Shadow mode for safe handler validation
- [x] Automatic pattern analysis and optimization

### Planned Features

- [ ] Conversation persistence (ETS/database)
- [ ] Multi-actor coordination patterns
- [ ] Built-in observability (metrics, tracing)
- [ ] Response streaming for long operations
- [ ] Vector memory for context retrieval
- [ ] Learning dashboards

### Research Directions

- Cross-actor knowledge sharing
- Automatic tool discovery
- Federated actor networks
- Formal verification of modifications

## References

- [OTP Design Principles](http://erlang.org/doc/design_principles/des_princ.html)
- [Claude API Documentation](https://docs.anthropic.com/)
- [Anthropic Tool Use Guide](https://docs.anthropic.com/en/docs/tool-use)
- [Elixir GenServer Docs](https://hexdocs.pm/elixir/GenServer.html)
