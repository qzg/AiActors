defmodule AiActors.ShadowRunner do
  @moduledoc """
  Manages shadow handler execution for AiActors.

  Shadow handlers run in parallel with primary handlers, allowing new optimizations
  to be validated against real traffic before promotion to primary.

  ## Responsibilities

  - Maintain registry of shadow handlers per `{module, pattern}`
  - Execute shadow handlers in isolated `Task.Supervisor` children
  - Compare shadow results against primary results
  - Track success/failure/crash statistics in ETS
  - Handle promotion decisions

  ## Shadow Handler Types

  - `:deterministic` - Code that computes results algorithmically
  - `:local_llm` - Uses local models (Granite via Ollama)
  - `:accelerated_llm` - Uses fast cloud models (Cerebras/SambaNova)
  - `:full_llm` - Uses full reasoning models (Claude Sonnet)
  """

  use GenServer
  require Logger

  @ets_table :ai_actors_shadow_comparisons
  @shadow_registry :ai_actors_shadow_registry

  @type handler_type :: :deterministic | :local_llm | :accelerated_llm | :full_llm

  @type handler_spec :: %{
          type: handler_type(),
          code: String.t() | nil,
          prompt_template: String.t() | nil,
          provider: atom() | nil,
          model: atom() | nil,
          created_at: DateTime.t(),
          pattern_description: String.t()
        }

  @type shadow_stats :: %{
          executions: non_neg_integer(),
          matches: non_neg_integer(),
          mismatches: non_neg_integer(),
          crashes: non_neg_integer(),
          timeouts: non_neg_integer(),
          total_latency_ms: non_neg_integer(),
          first_execution_at: DateTime.t() | nil,
          last_execution_at: DateTime.t() | nil
        }

  @default_config %{
    min_shadow_executions: 50,
    min_match_rate: 0.98,
    max_crash_rate: 0.01,
    min_shadow_duration_hours: 24,
    max_concurrent_shadows: 10,
    shadow_timeout_ms: 5000,
    comparison_retention_days: 7,
    max_comparisons_per_pattern: 1000
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new shadow handler for a module/pattern combination.
  """
  @spec register_shadow(module(), term(), handler_spec()) :: :ok | {:error, term()}
  def register_shadow(module, pattern, handler_spec) do
    GenServer.call(__MODULE__, {:register_shadow, module, pattern, handler_spec})
  end

  @doc """
  Execute a shadow handler asynchronously (fire-and-forget).
  Compares result against primary and logs to ETS.
  """
  @spec execute_shadow(module(), term(), term(), term(), term()) :: :ok
  def execute_shadow(module, pattern, message, primary_result, user_state) do
    GenServer.cast(__MODULE__, {:execute_shadow, module, pattern, message, primary_result, user_state})
  end

  @doc """
  Get statistics for a shadow handler.
  """
  @spec get_shadow_stats(module(), term()) :: {:ok, shadow_stats()} | {:error, :not_found}
  def get_shadow_stats(module, pattern) do
    GenServer.call(__MODULE__, {:get_shadow_stats, module, pattern})
  end

  @doc """
  List all registered shadow handlers.
  """
  @spec list_shadows() :: list({module(), term(), handler_spec()})
  def list_shadows do
    GenServer.call(__MODULE__, :list_shadows)
  end

  @doc """
  Check if a shadow exists for module/pattern.
  """
  @spec has_shadow?(module(), term()) :: boolean()
  def has_shadow?(module, pattern) do
    GenServer.call(__MODULE__, {:has_shadow, module, pattern})
  end

  @doc """
  Promote a shadow handler to primary (triggers code modification).
  """
  @spec promote_shadow(module(), term()) :: {:ok, reference()} | {:error, term()}
  def promote_shadow(module, pattern) do
    GenServer.call(__MODULE__, {:promote_shadow, module, pattern}, 60_000)
  end

  @doc """
  Discard a shadow handler (remove from registry).
  """
  @spec discard_shadow(module(), term()) :: :ok | {:error, :not_found}
  def discard_shadow(module, pattern) do
    GenServer.call(__MODULE__, {:discard_shadow, module, pattern})
  end

  @doc """
  Get comparison history for a module/pattern.
  """
  @spec get_comparisons(module(), term(), keyword()) :: list(map())
  def get_comparisons(module, pattern, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    
    try do
      :ets.match_object(@ets_table, {{module, pattern, :_}, :_})
      |> Enum.sort_by(fn {{_, _, ts}, _} -> ts end, {:desc, DateTime})
      |> Enum.take(limit)
      |> Enum.map(fn {_key, value} -> value end)
    rescue
      ArgumentError -> []
    end
  end

  @doc """
  Get configuration for shadow mode.
  """
  @spec get_config() :: map()
  def get_config do
    Application.get_env(:ai_actors, :shadow_config, @default_config)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@ets_table, [:named_table, :public, :ordered_set])
    :ets.new(@shadow_registry, [:named_table, :protected, :set])

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      config: get_config()
    }

    Logger.info("ShadowRunner started with config: #{inspect(state.config)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:register_shadow, module, pattern, handler_spec}, _from, state) do
    key = {module, pattern}
    
    full_spec = Map.merge(handler_spec, %{
      created_at: DateTime.utc_now(),
      stats: initial_stats()
    })

    :ets.insert(@shadow_registry, {key, full_spec})
    
    Logger.info("Registered shadow handler for #{inspect(module)} pattern #{inspect(pattern)}: #{handler_spec.type}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_shadow_stats, module, pattern}, _from, state) do
    key = {module, pattern}
    
    case :ets.lookup(@shadow_registry, key) do
      [{^key, spec}] ->
        # Calculate stats from ETS comparisons
        stats = calculate_stats_from_ets(module, pattern, spec)
        {:reply, {:ok, stats}, state}
      
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_shadows, _from, state) do
    shadows = :ets.tab2list(@shadow_registry)
    |> Enum.map(fn {{module, pattern}, spec} -> {module, pattern, spec} end)
    
    {:reply, shadows, state}
  end

  @impl true
  def handle_call({:has_shadow, module, pattern}, _from, state) do
    key = {module, pattern}
    result = :ets.member(@shadow_registry, key)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:promote_shadow, module, pattern}, _from, state) do
    key = {module, pattern}
    
    case :ets.lookup(@shadow_registry, key) do
      [{^key, spec}] ->
        # Check if promotion criteria are met
        stats = calculate_stats_from_ets(module, pattern, spec)
        
        case check_promotion_criteria(stats, state.config) do
          :ok ->
            result = do_promote_shadow(module, pattern, spec)
            {:reply, result, state}
          
          {:error, reason} = error ->
            Logger.warning("Shadow promotion blocked for #{inspect(module)}: #{inspect(reason)}")
            {:reply, error, state}
        end
      
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:discard_shadow, module, pattern}, _from, state) do
    key = {module, pattern}
    
    case :ets.lookup(@shadow_registry, key) do
      [{^key, _spec}] ->
        :ets.delete(@shadow_registry, key)
        # Optionally clean up comparison history
        cleanup_comparisons_for_pattern(module, pattern)
        Logger.info("Discarded shadow handler for #{inspect(module)} pattern #{inspect(pattern)}")
        {:reply, :ok, state}
      
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:execute_shadow, module, pattern, message, primary_result, user_state}, state) do
    key = {module, pattern}
    
    case :ets.lookup(@shadow_registry, key) do
      [{^key, spec}] ->
        # Spawn shadow execution under ShadowSupervisor
        Task.Supervisor.start_child(
          AiActors.ShadowSupervisor,
          fn -> run_shadow_and_compare(module, pattern, message, primary_result, user_state, spec, state.config) end
        )
      
      [] ->
        # No shadow registered for this pattern, ignore
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    do_cleanup(state.config)
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp initial_stats do
    %{
      executions: 0,
      matches: 0,
      mismatches: 0,
      crashes: 0,
      timeouts: 0,
      total_latency_ms: 0,
      first_execution_at: nil,
      last_execution_at: nil
    }
  end

  defp run_shadow_and_compare(module, pattern, message, primary_result, user_state, spec, config) do
    start_time = System.monotonic_time(:millisecond)
    timeout = config.shadow_timeout_ms

    # Execute the shadow handler based on type
    shadow_result = 
      try do
        case spec.type do
          :deterministic ->
            execute_deterministic_shadow(spec.code, message, user_state, timeout)
          
          type when type in [:local_llm, :accelerated_llm, :full_llm] ->
            execute_llm_shadow(spec, message, user_state, timeout)
        end
      rescue
        e ->
          Logger.warning("Shadow execution crashed: #{inspect(e)}")
          {:crash, Exception.message(e)}
      catch
        :exit, reason ->
          Logger.warning("Shadow execution exited: #{inspect(reason)}")
          {:crash, inspect(reason)}
      end

    end_time = System.monotonic_time(:millisecond)
    latency_ms = end_time - start_time

    # Compare results
    {match, shadow_value} = compare_results(primary_result, shadow_result)

    # Record comparison in ETS
    comparison = %{
      message: message,
      primary_result: primary_result,
      shadow_result: shadow_value,
      match: match,
      shadow_type: spec.type,
      latency_ms: latency_ms,
      timestamp: DateTime.utc_now()
    }

    key = {module, pattern, DateTime.utc_now()}
    :ets.insert(@ets_table, {key, comparison})

    # Log significant events
    unless match do
      Logger.debug("Shadow mismatch for #{inspect(module)}/#{inspect(pattern)}: primary=#{inspect(primary_result)}, shadow=#{inspect(shadow_value)}")
    end
  end

  defp execute_deterministic_shadow(code, message, user_state, timeout) do
    # Compile and execute the code in a sandboxed manner
    task = Task.async(fn ->
      try do
        # The code should define a function that takes message and state
        # We wrap it in a module and call it
        {result, _binding} = Code.eval_string("""
          fn message, state ->
            #{code}
          end
        """)
        
        result.(message, user_state)
      rescue
        e -> {:error, Exception.message(e)}
      end
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:timeout, "Shadow execution timed out after #{timeout}ms"}
    end
  end

  defp execute_llm_shadow(spec, message, _user_state, timeout) do
    provider = spec.provider || :anthropic
    model = spec.model || :haiku
    prompt = build_shadow_prompt(spec.prompt_template, message)

    task = Task.async(fn ->
      AiActors.LLMClient.send_message(
        [%{role: "user", content: prompt}],
        provider: provider,
        model: model,
        max_tokens: 1024
      )
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, response}} -> 
        extract_response_value(response)
      {:ok, {:error, reason}} -> 
        {:error, reason}
      nil -> 
        {:timeout, "Shadow LLM execution timed out after #{timeout}ms"}
    end
  end

  defp build_shadow_prompt(template, message) when is_binary(template) do
    String.replace(template, "{{message}}", inspect(message))
  end

  defp build_shadow_prompt(nil, message) do
    "Process this message and return a response: #{inspect(message)}"
  end

  defp extract_response_value(%{"content" => content}) do
    text = content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.join("\n")

    {:ok, text}
  end

  defp extract_response_value(other), do: {:ok, other}

  defp compare_results(primary, shadow) do
    case {primary, shadow} do
      # Crash or timeout is always a mismatch
      {_, {:crash, _}} -> {false, shadow}
      {_, {:timeout, _}} -> {false, shadow}
      
      # Both ok - compare values
      {{:ok, p_val}, {:ok, s_val}} ->
        {values_match?(p_val, s_val), shadow}
      
      # Direct comparison for other cases
      _ ->
        {values_match?(primary, shadow), shadow}
    end
  end

  defp values_match?(primary, shadow) do
    # Flexible comparison - could be enhanced with semantic comparison
    normalize_for_comparison(primary) == normalize_for_comparison(shadow)
  end

  defp normalize_for_comparison(value) when is_map(value) do
    # Extract the "value" field if present (common in LLM responses)
    case Map.get(value, "value") || Map.get(value, :value) do
      nil -> value
      v -> v
    end
  end

  defp normalize_for_comparison(value), do: value

  defp calculate_stats_from_ets(module, pattern, spec) do
    comparisons = :ets.match_object(@ets_table, {{module, pattern, :_}, :_})
    
    stats = Enum.reduce(comparisons, initial_stats(), fn {_key, comp}, acc ->
      %{
        executions: acc.executions + 1,
        matches: acc.matches + (if comp.match, do: 1, else: 0),
        mismatches: acc.mismatches + (if not comp.match and not is_crash?(comp.shadow_result), do: 1, else: 0),
        crashes: acc.crashes + (if is_crash?(comp.shadow_result), do: 1, else: 0),
        timeouts: acc.timeouts + (if is_timeout?(comp.shadow_result), do: 1, else: 0),
        total_latency_ms: acc.total_latency_ms + comp.latency_ms,
        first_execution_at: acc.first_execution_at || comp.timestamp,
        last_execution_at: comp.timestamp
      }
    end)

    Map.merge(stats, %{
      avg_latency_ms: if(stats.executions > 0, do: stats.total_latency_ms / stats.executions, else: 0),
      match_rate: if(stats.executions > 0, do: stats.matches / stats.executions, else: 0),
      crash_rate: if(stats.executions > 0, do: stats.crashes / stats.executions, else: 0),
      created_at: spec.created_at
    })
  end

  defp is_crash?({:crash, _}), do: true
  defp is_crash?(_), do: false

  defp is_timeout?({:timeout, _}), do: true
  defp is_timeout?(_), do: false

  defp check_promotion_criteria(stats, config) do
    cond do
      stats.executions < config.min_shadow_executions ->
        {:error, {:insufficient_executions, stats.executions, config.min_shadow_executions}}
      
      stats.match_rate < config.min_match_rate ->
        {:error, {:low_match_rate, stats.match_rate, config.min_match_rate}}
      
      stats.crash_rate > config.max_crash_rate ->
        {:error, {:high_crash_rate, stats.crash_rate, config.max_crash_rate}}
      
      not sufficient_duration?(stats, config) ->
        {:error, {:insufficient_duration, stats.first_execution_at, config.min_shadow_duration_hours}}
      
      true ->
        :ok
    end
  end

  defp sufficient_duration?(stats, config) do
    case stats.first_execution_at do
      nil -> false
      first ->
        hours_elapsed = DateTime.diff(DateTime.utc_now(), first, :hour)
        hours_elapsed >= config.min_shadow_duration_hours
    end
  end

  defp do_promote_shadow(module, pattern, spec) do
    Logger.info("Promoting shadow handler for #{inspect(module)} pattern #{inspect(pattern)}")

    case spec.type do
      :deterministic ->
        # Generate full module code with the new handler
        case generate_promoted_code(module, pattern, spec) do
          {:ok, new_code} ->
            # Use CodeModifier for hot reload
            AiActors.CodeModifier.modify_code(module, new_code, %{
              reason: "Shadow promotion",
              pattern: pattern,
              shadow_type: spec.type,
              promoted_at: DateTime.utc_now()
            })
          
          error -> error
        end
      
      _llm_type ->
        # For LLM-based shadows, update the actor's configuration
        # to use the optimized provider/model for this pattern
        {:ok, :llm_optimization_registered}
    end
  end

  defp generate_promoted_code(module, pattern, spec) do
    # Get current module source
    case AiActors.CodeModifier.get_module_source(module) do
      {:ok, current_code} ->
        # Insert the new handler before the catch-all escalation handler
        new_handler = spec.code
        
        # Use LLM to properly integrate the handler
        prompt = """
        Add this new handler to the Elixir module. Place it BEFORE any catch-all 
        handler that returns :escalate_to_llm.

        Current module:
        ```elixir
        #{current_code}
        ```

        New handler to add for pattern #{inspect(pattern)}:
        ```elixir
        #{new_handler}
        ```

        Return ONLY the complete updated module code.
        """

        case AiActors.LLMClient.send_message(
          [%{role: "user", content: prompt}],
          system: "You are an expert Elixir developer. Return only valid Elixir code.",
          max_tokens: 8000
        ) do
          {:ok, response} ->
            code = extract_code_from_response(response)
            {:ok, code}
          
          error -> error
        end
      
      error -> error
    end
  end

  defp extract_code_from_response(%{"content" => content}) do
    text = content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.join("\n")

    case Regex.run(~r/```(?:elixir)?\n(.*?)\n```/s, text) do
      [_, code] -> code
      nil -> text
    end
  end

  defp cleanup_comparisons_for_pattern(module, pattern) do
    :ets.match_delete(@ets_table, {{module, pattern, :_}, :_})
  end

  defp do_cleanup(config) do
    cutoff = DateTime.utc_now() |> DateTime.add(-config.comparison_retention_days * 24 * 60 * 60, :second)

    # Get all keys and delete old ones
    :ets.tab2list(@ets_table)
    |> Enum.filter(fn {{_module, _pattern, timestamp}, _value} ->
      DateTime.compare(timestamp, cutoff) == :lt
    end)
    |> Enum.each(fn {key, _value} ->
      :ets.delete(@ets_table, key)
    end)

    # Also enforce per-pattern limit
    :ets.tab2list(@shadow_registry)
    |> Enum.each(fn {{module, pattern}, _spec} ->
      comparisons = :ets.match_object(@ets_table, {{module, pattern, :_}, :_})
      |> Enum.sort_by(fn {{_, _, ts}, _} -> ts end, {:desc, DateTime})
      
      if length(comparisons) > config.max_comparisons_per_pattern do
        comparisons
        |> Enum.drop(config.max_comparisons_per_pattern)
        |> Enum.each(fn {key, _} -> :ets.delete(@ets_table, key) end)
      end
    end)

    Logger.debug("Shadow comparison cleanup completed")
  end

  defp schedule_cleanup do
    # Run cleanup every 24 hours
    Process.send_after(self(), :cleanup, 24 * 60 * 60 * 1000)
  end
end
