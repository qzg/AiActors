defmodule AiActors.EscalationTrackerTest do
  use ExUnit.Case, async: false

  alias AiActors.EscalationTracker

  setup do
    # Ensure tracker is started
    case GenServer.whereis(EscalationTracker) do
      nil ->
        {:ok, _pid} = start_supervised(EscalationTracker)

      _pid ->
        :ok
    end

    :ok
  end

  describe "log_escalation/6" do
    test "logs escalation successfully" do
      EscalationTracker.log_escalation(
        TestModule,
        self(),
        {:test, :message},
        :call,
        {:ok, %{"response" => "test"}},
        150
      )

      # Give it time to process
      Process.sleep(50)

      escalations = EscalationTracker.get_escalations(TestModule)
      assert length(escalations) >= 1

      last_escalation = List.first(escalations)
      assert last_escalation.actor_module == TestModule
      assert last_escalation.message == {:test, :message}
      assert last_escalation.message_type == :call
    end
  end

  describe "log_handler_execution/7" do
    test "logs handler execution successfully" do
      EscalationTracker.log_handler_execution(
        TestModule,
        self(),
        :test_handler,
        {:test, :message},
        {:ok, :result},
        10,
        true
      )

      # Give it time to process
      Process.sleep(50)

      executions = EscalationTracker.get_handler_executions(TestModule)
      assert length(executions) >= 1

      last_execution = List.first(executions)
      assert last_execution.actor_module == TestModule
      assert last_execution.handler_name == :test_handler
      assert last_execution.success == true
    end
  end

  describe "get_escalations/2" do
    test "filters by limit" do
      module = LimitTestModule

      # Log multiple escalations
      for i <- 1..5 do
        EscalationTracker.log_escalation(
          module,
          self(),
          {:test, i},
          :call,
          {:ok, %{}},
          100
        )
      end

      Process.sleep(50)

      escalations = EscalationTracker.get_escalations(module, limit: 3)
      assert length(escalations) == 3
    end
  end

  describe "get_statistics/1" do
    test "returns statistics for module" do
      module = StatsTestModule

      # Log some data
      EscalationTracker.log_escalation(module, self(), :test, :call, {:ok, %{}}, 100)
      EscalationTracker.log_handler_execution(module, self(), :handler, :test, :ok, 10, true)

      Process.sleep(50)

      stats = EscalationTracker.get_statistics(module)

      assert is_map(stats)
      assert Map.has_key?(stats, :total_escalations)
      assert Map.has_key?(stats, :total_handler_executions)
      assert Map.has_key?(stats, :avg_escalation_time_ms)
      assert Map.has_key?(stats, :handler_success_rate)
    end
  end

  describe "analyze_patterns/1" do
    test "analyzes patterns when sufficient data exists" do
      module = PatternTestModule

      # Create a pattern by repeating similar messages
      for _i <- 1..6 do
        EscalationTracker.log_escalation(
          module,
          self(),
          {:multiply, 2},
          :call,
          {:ok, %{}},
          100
        )
      end

      Process.sleep(50)

      {:ok, analysis} = EscalationTracker.analyze_patterns(module)

      assert analysis.actor_module == module
      assert is_list(analysis.patterns_found)
      # Should find at least one pattern
      assert length(analysis.patterns_found) >= 1
    end

    test "returns message when insufficient data" do
      module = InsufficientDataModule

      # Only log a couple escalations
      EscalationTracker.log_escalation(module, self(), :test1, :call, {:ok, %{}}, 100)
      EscalationTracker.log_escalation(module, self(), :test2, :call, {:ok, %{}}, 100)

      Process.sleep(50)

      {:ok, analysis} = EscalationTracker.analyze_patterns(module)

      assert analysis.patterns_found == []
      assert String.contains?(analysis.message, "Not enough escalations")
    end
  end

  describe "cleanup_old_logs/1" do
    test "removes old log entries" do
      # This test would need to manipulate timestamps to fully test
      # For now, just verify it doesn't crash
      assert :ok = EscalationTracker.cleanup_old_logs(30)
    end
  end
end
