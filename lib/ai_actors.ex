defmodule AiActors do
  @moduledoc """
  AiActors - Intelligent GenServers powered by Large Language Models.

  ## Overview

  AiActors is a framework for building GenServers that can leverage LLM capabilities
  to handle complex, unstructured interactions while maintaining the reliability
  and performance of traditional Erlang/Elixir actors.

  ## Key Modules

  - `AiActors.AiActor` - The main behavior for creating intelligent actors
  - `AiActors.LLMClient` - Client for interacting with Claude API
  - `AiActors.CodeModifier` - Service for hot code reloading
  - `AiActors.ClaudeIntegration` - Two-phase workflow for component creation

  ## Quick Example

      defmodule MyApp.SmartCounter do
        use AiActors.AiActor

        def init(_), do: {:ok, %{count: 0}}

        def development_metadata do
          %{purpose: "A counter that understands natural language", version: "1.0.0"}
        end

        def handle_call({:increment, n}, _from, state) do
          {:reply, state.count + n, %{state | count: state.count + n}}
        end

        # Unknown messages go to LLM
        def handle_call(_msg, _from, _state), do: :escalate_to_llm
      end

      # Start and use
      {:ok, pid} = MyApp.SmartCounter.start_link([])
      GenServer.call(pid, {:increment, 5})  # => 5

      # Natural language query goes to LLM
      MyApp.SmartCounter.ask_llm(pid, "What's the current count?")

  ## Architecture

  ```
  ┌──────────────┐
  │   AiActor    │ ← Your intelligent GenServer
  └──────┬───────┘
         │
         ├─→ Known messages: Handle explicitly
         │
         └─→ Unknown messages: Escalate to LLM
                 │
                 ├─→ LLM can call tools
                 │
                 └─→ Returns structured response
  ```

  ## Configuration

  Set your API key:

      export ANTHROPIC_API_KEY="your-key"

  Configure in config/config.exs:

      config :ai_actors,
        llm_model: "claude-sonnet-4-5-20250929",
        max_tokens: 4096

  See README.md for complete documentation.
  """

  @doc """
  Returns the version of AiActors.
  """
  def version, do: "0.1.0"
end
