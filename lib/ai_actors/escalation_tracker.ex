defmodule AiActors.EscalationTracker do
  @moduledoc """
  Tracks LLM escalations and handler executions for AiActors.

  This service maintains logs of:
  - When messages were escalated to LLM
  - What the LLM responses were
  - Handler executions and their outputs
  - Pattern analysis results

  Used for:
  - Identifying common patterns that should be handled deterministically
  - Validating that new handlers work correctly
  - Observability and debugging
  """

  use GenServer
  require Logger

  @type escalation_entry :: %{
          actor_module: module(),
          actor_pid: pid(),
          message: term(),
          message_type: :call | :cast | :info,
          llm_response: term(),
          timestamp: DateTime.t(),
          execution_time_ms: non_neg_integer()
        }

  @type handler_execution :: %{
          actor_module: module(),
          actor_pid: pid(),
          handler_name: atom(),
          message: term(),
          response: term(),
          timestamp: DateTime.t(),
          execution_time_ms: non_neg_integer(),
          success: boolean()
        }

  @type pattern_analysis :: %{
          actor_module: module(),
          analyzed_at: DateTime.t(),
          patterns_found: list(map()),
          recommendations: list(map())
        }

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Log an LLM escalation.
  """
  @spec log_escalation(module(), pid(), term(), atom(), term(), non_neg_integer()) :: :ok
  def log_escalation(actor_module, actor_pid, message, message_type, llm_response, execution_time_ms) do
    entry = %{
      actor_module: actor_module,
      actor_pid: actor_pid,
      message: message,
      message_type: message_type,
      llm_response: llm_response,
      timestamp: DateTime.utc_now(),
      execution_time_ms: execution_time_ms
    }

    GenServer.cast(__MODULE__, {:log_escalation, entry})
  end

  @doc """
  Log a handler execution (for newly learned handlers).
  """
  @spec log_handler_execution(module(), pid(), atom(), term(), term(), non_neg_integer(), boolean()) :: :ok
  def log_handler_execution(actor_module, actor_pid, handler_name, message, response, execution_time_ms, success) do
    entry = %{
      actor_module: actor_module,
      actor_pid: actor_pid,
      handler_name: handler_name,
      message: message,
      response: response,
      timestamp: DateTime.utc_now(),
      execution_time_ms: execution_time_ms,
      success: success
    }

    GenServer.cast(__MODULE__, {:log_handler_execution, entry})
  end

  @doc """
  Get escalation history for a specific actor module.
  """
  @spec get_escalations(module(), keyword()) :: list(escalation_entry())
  def get_escalations(actor_module, opts \\ []) do
    GenServer.call(__MODULE__, {:get_escalations, actor_module, opts})
  end

  @doc """
  Get handler execution history for a specific actor module.
  """
  @spec get_handler_executions(module(), keyword()) :: list(handler_execution())
  def get_handler_executions(actor_module, opts \\ []) do
    GenServer.call(__MODULE__, {:get_handler_executions, actor_module, opts})
  end

  @doc """
  Analyze patterns for a specific actor module.
  Returns suggestions for new deterministic handlers.
  """
  @spec analyze_patterns(module()) :: {:ok, pattern_analysis()} | {:error, term()}
  def analyze_patterns(actor_module) do
    GenServer.call(__MODULE__, {:analyze_patterns, actor_module}, 60_000)
  end

  @doc """
  Get statistics for an actor module.
  """
  @spec get_statistics(module()) :: map()
  def get_statistics(actor_module) do
    GenServer.call(__MODULE__, {:get_statistics, actor_module})
  end

  @doc """
  Clear old logs (retention policy).
  """
  @spec cleanup_old_logs(non_neg_integer()) :: :ok
  def cleanup_old_logs(days_to_keep \\ 30) do
    GenServer.cast(__MODULE__, {:cleanup_old_logs, days_to_keep})
  end

  # Server Callbacks

  @impl true
  def init(_) do
    state = %{
      escalations: [],
      handler_executions: [],
      pattern_analyses: %{},
      last_cleanup: DateTime.utc_now()
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_cast({:log_escalation, entry}, state) do
    new_escalations = [entry | state.escalations]

    # Trim if too large (keep last 10000)
    new_escalations = Enum.take(new_escalations, 10_000)

    {:noreply, %{state | escalations: new_escalations}}
  end

  @impl true
  def handle_cast({:log_handler_execution, entry}, state) do
    new_executions = [entry | state.handler_executions]

    # Trim if too large (keep last 10000)
    new_executions = Enum.take(new_executions, 10_000)

    {:noreply, %{state | handler_executions: new_executions}}
  end

  @impl true
  def handle_cast({:cleanup_old_logs, days_to_keep}, state) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days_to_keep * 24 * 60 * 60, :second)

    new_escalations =
      Enum.filter(state.escalations, fn entry ->
        DateTime.compare(entry.timestamp, cutoff) == :gt
      end)

    new_executions =
      Enum.filter(state.handler_executions, fn entry ->
        DateTime.compare(entry.timestamp, cutoff) == :gt
      end)

    Logger.info("Cleaned up old logs. Kept #{length(new_escalations)} escalations, #{length(new_executions)} executions")

    {:noreply,
     %{
       state
       | escalations: new_escalations,
         handler_executions: new_executions,
         last_cleanup: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_call({:get_escalations, actor_module, opts}, _from, state) do
    escalations =
      state.escalations
      |> Enum.filter(&(&1.actor_module == actor_module))
      |> apply_filters(opts)

    {:reply, escalations, state}
  end

  @impl true
  def handle_call({:get_handler_executions, actor_module, opts}, _from, state) do
    executions =
      state.handler_executions
      |> Enum.filter(&(&1.actor_module == actor_module))
      |> apply_filters(opts)

    {:reply, executions, state}
  end

  @impl true
  def handle_call({:analyze_patterns, actor_module}, _from, state) do
    result = do_analyze_patterns(actor_module, state)

    new_analyses =
      Map.put(state.pattern_analyses, actor_module, %{
        result: result,
        analyzed_at: DateTime.utc_now()
      })

    {:reply, result, %{state | pattern_analyses: new_analyses}}
  end

  @impl true
  def handle_call({:get_statistics, actor_module}, _from, state) do
    escalations = Enum.filter(state.escalations, &(&1.actor_module == actor_module))
    executions = Enum.filter(state.handler_executions, &(&1.actor_module == actor_module))

    stats = %{
      total_escalations: length(escalations),
      total_handler_executions: length(executions),
      avg_escalation_time_ms:
        if(length(escalations) > 0,
          do: Enum.sum(Enum.map(escalations, & &1.execution_time_ms)) / length(escalations),
          else: 0
        ),
      avg_handler_time_ms:
        if(length(executions) > 0,
          do: Enum.sum(Enum.map(executions, & &1.execution_time_ms)) / length(executions),
          else: 0
        ),
      handler_success_rate:
        if(length(executions) > 0,
          do: Enum.count(executions, & &1.success) / length(executions),
          else: 1.0
        ),
      recent_escalations: Enum.take(escalations, 10),
      recent_executions: Enum.take(executions, 10)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Auto cleanup every 24 hours
    send(self(), :cleanup)
    schedule_cleanup()

    {:noreply, state}
  end

  # Private Functions

  defp apply_filters(entries, opts) do
    entries
    |> maybe_filter_limit(opts[:limit])
    |> maybe_filter_since(opts[:since])
  end

  defp maybe_filter_limit(entries, nil), do: entries
  defp maybe_filter_limit(entries, limit), do: Enum.take(entries, limit)

  defp maybe_filter_since(entries, nil), do: entries

  defp maybe_filter_since(entries, since) do
    Enum.filter(entries, fn entry ->
      DateTime.compare(entry.timestamp, since) == :gt
    end)
  end

  defp do_analyze_patterns(actor_module, state) do
    escalations = Enum.filter(state.escalations, &(&1.actor_module == actor_module))
    executions = Enum.filter(state.handler_executions, &(&1.actor_module == actor_module))

    if length(escalations) < 5 do
      {:ok,
       %{
         actor_module: actor_module,
         analyzed_at: DateTime.utc_now(),
         patterns_found: [],
         recommendations: [],
         message: "Not enough escalations to analyze (need at least 5)"
       }}
    else
      # Group escalations by message pattern
      grouped = group_by_pattern(escalations)

      # Find patterns that occur frequently
      frequent_patterns =
        grouped
        |> Enum.filter(fn {_pattern, entries} -> length(entries) >= 3 end)
        |> Enum.map(fn {pattern, entries} ->
          %{
            pattern: pattern,
            occurrences: length(entries),
            avg_execution_time_ms:
              Enum.sum(Enum.map(entries, & &1.execution_time_ms)) / length(entries),
            examples: Enum.take(entries, 3)
          }
        end)
        |> Enum.sort_by(& &1.occurrences, :desc)

      # Generate recommendations via LLM
      recommendations =
        if length(frequent_patterns) > 0 do
          generate_handler_recommendations(actor_module, frequent_patterns, executions)
        else
          []
        end

      {:ok,
       %{
         actor_module: actor_module,
         analyzed_at: DateTime.utc_now(),
         patterns_found: frequent_patterns,
         recommendations: recommendations,
         total_escalations: length(escalations),
         total_patterns: length(grouped)
       }}
    end
  end

  defp group_by_pattern(escalations) do
    Enum.group_by(escalations, fn entry ->
      # Group by message structure (not exact values)
      normalize_message_pattern(entry.message)
    end)
  end

  defp normalize_message_pattern(message) when is_tuple(message) do
    # For tuples like {:increment, 5} -> {:increment, :_}
    message
    |> Tuple.to_list()
    |> Enum.map(fn
      x when is_atom(x) -> x
      x when is_binary(x) -> :_string
      x when is_number(x) -> :_number
      x when is_list(x) -> :_list
      x when is_map(x) -> :_map
      _ -> :_other
    end)
    |> List.to_tuple()
  end

  defp normalize_message_pattern(message) when is_atom(message), do: message
  defp normalize_message_pattern(message) when is_binary(message), do: :string_message
  defp normalize_message_pattern(message) when is_map(message), do: :map_message
  defp normalize_message_pattern(_), do: :unknown_message

  defp generate_handler_recommendations(actor_module, patterns, handler_executions) do
    # Ask LLM to generate handler code for these patterns
    prompt = build_recommendation_prompt(actor_module, patterns, handler_executions)

    case AiActors.LLMClient.send_message(
           [%{role: "user", content: prompt}],
           system: "You are a code generation expert for Elixir GenServers.",
           max_tokens: 4096,
           structured_output: %{
             type: "object",
             properties: %{
               recommendations: %{
                 type: "array",
                 items: %{
                   type: "object",
                   properties: %{
                     pattern: %{type: "string"},
                     handler_code: %{type: "string"},
                     rationale: %{type: "string"},
                     estimated_speedup: %{type: "string"}
                   }
                 }
               }
             }
           }
         ) do
      {:ok, response} ->
        case AiActors.LLMClient.parse_structured_response(response) do
          {:ok, %{"recommendations" => recs}} -> recs
          _ -> []
        end

      {:error, reason} ->
        Logger.error("Failed to generate handler recommendations: #{inspect(reason)}")
        []
    end
  end

  defp build_recommendation_prompt(actor_module, patterns, handler_executions) do
    """
    Analyze the following escalation patterns for module #{inspect(actor_module)} and suggest
    deterministic handler implementations.

    ## Frequent Escalation Patterns

    #{Enum.map_join(patterns, "\n\n", fn pattern ->
      """
      Pattern: #{inspect(pattern.pattern)}
      Occurrences: #{pattern.occurrences}
      Avg execution time: #{pattern.avg_execution_time_ms}ms

      Examples:
      #{Enum.map_join(pattern.examples, "\n", fn ex ->
        "  Message: #{inspect(ex.message)}"
      end)}
      """
    end)}

    ## Recently Implemented Handlers

    #{if length(handler_executions) > 0 do
      "These handlers were recently added (for reference):\n" <>
        Enum.map_join(Enum.take(handler_executions, 5), "\n", fn ex ->
          "- #{ex.handler_name}: #{if ex.success, do: "✓", else: "✗"} (#{ex.execution_time_ms}ms)"
        end)
    else
      "No handlers have been implemented yet."
    end}

    ## Task

    For each frequent pattern:
    1. Generate Elixir handler code (handle_call/handle_cast)
    2. Explain the rationale
    3. Estimate performance improvement vs LLM escalation

    Return a list of recommendations with:
    - pattern: String description
    - handler_code: Complete Elixir function code
    - rationale: Why this should be deterministic
    - estimated_speedup: Expected performance gain
    """
  end

  defp schedule_cleanup do
    # Schedule cleanup every 24 hours
    Process.send_after(self(), :cleanup, 24 * 60 * 60 * 1000)
  end
end
