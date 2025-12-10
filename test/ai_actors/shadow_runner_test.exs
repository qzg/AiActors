defmodule AiActors.ShadowRunnerTest do
  use ExUnit.Case, async: false

  alias AiActors.ShadowRunner

  setup do
    # Ensure ShadowRunner is started
    case Process.whereis(ShadowRunner) do
      nil ->
        {:ok, _pid} = ShadowRunner.start_link([])
      pid ->
        # Clear any existing shadows for test isolation
        for {module, pattern, _spec} <- ShadowRunner.list_shadows() do
          ShadowRunner.discard_shadow(module, pattern)
        end
        {:ok, pid}
    end

    :ok
  end

  describe "register_shadow/3" do
    test "registers a deterministic shadow handler" do
      handler_spec = %{
        type: :deterministic,
        code: "case message do {:multiply, n} -> {:reply, n * n, state} end",
        prompt_template: nil,
        provider: nil,
        model: nil,
        created_at: DateTime.utc_now(),
        pattern_description: "{:multiply, :_number}"
      }

      assert :ok = ShadowRunner.register_shadow(TestModule, {:multiply, :_number}, handler_spec)
      assert ShadowRunner.has_shadow?(TestModule, {:multiply, :_number}) == true
    end

    test "registers an LLM-based shadow handler" do
      handler_spec = %{
        type: :local_llm,
        code: nil,
        prompt_template: "Handle: {{message}}",
        provider: :ollama,
        model: :granite_micro,
        created_at: DateTime.utc_now(),
        pattern_description: "{:complex, :_string}"
      }

      assert :ok = ShadowRunner.register_shadow(TestModule, {:complex, :_string}, handler_spec)
      assert ShadowRunner.has_shadow?(TestModule, {:complex, :_string}) == true
    end
  end

  describe "list_shadows/0" do
    test "returns all registered shadows" do
      # Register multiple shadows
      spec1 = %{
        type: :deterministic,
        code: "code1",
        prompt_template: nil,
        provider: nil,
        model: nil,
        created_at: DateTime.utc_now(),
        pattern_description: "pattern1"
      }

      spec2 = %{
        type: :local_llm,
        code: nil,
        prompt_template: "template",
        provider: :ollama,
        model: :granite_micro,
        created_at: DateTime.utc_now(),
        pattern_description: "pattern2"
      }

      ShadowRunner.register_shadow(Module1, :pattern1, spec1)
      ShadowRunner.register_shadow(Module2, :pattern2, spec2)

      shadows = ShadowRunner.list_shadows()

      assert length(shadows) >= 2
      assert Enum.any?(shadows, fn {m, p, _} -> m == Module1 and p == :pattern1 end)
      assert Enum.any?(shadows, fn {m, p, _} -> m == Module2 and p == :pattern2 end)
    end
  end

  describe "has_shadow?/2" do
    test "returns true for registered shadow" do
      spec = %{
        type: :deterministic,
        code: "code",
        prompt_template: nil,
        provider: nil,
        model: nil,
        created_at: DateTime.utc_now(),
        pattern_description: "test"
      }

      ShadowRunner.register_shadow(TestModule, :test_pattern, spec)

      assert ShadowRunner.has_shadow?(TestModule, :test_pattern) == true
    end

    test "returns false for unregistered shadow" do
      assert ShadowRunner.has_shadow?(NonExistent, :fake_pattern) == false
    end
  end

  describe "discard_shadow/2" do
    test "removes a registered shadow" do
      spec = %{
        type: :deterministic,
        code: "code",
        prompt_template: nil,
        provider: nil,
        model: nil,
        created_at: DateTime.utc_now(),
        pattern_description: "test"
      }

      ShadowRunner.register_shadow(DiscardTest, :pattern, spec)
      assert ShadowRunner.has_shadow?(DiscardTest, :pattern) == true

      assert :ok = ShadowRunner.discard_shadow(DiscardTest, :pattern)
      assert ShadowRunner.has_shadow?(DiscardTest, :pattern) == false
    end

    test "returns error for non-existent shadow" do
      assert {:error, :not_found} = ShadowRunner.discard_shadow(NonExistent, :fake)
    end
  end

  describe "get_shadow_stats/2" do
    test "returns stats for registered shadow with no executions" do
      spec = %{
        type: :deterministic,
        code: "code",
        prompt_template: nil,
        provider: nil,
        model: nil,
        created_at: DateTime.utc_now(),
        pattern_description: "test"
      }

      ShadowRunner.register_shadow(StatsTest, :pattern, spec)

      assert {:ok, stats} = ShadowRunner.get_shadow_stats(StatsTest, :pattern)
      assert stats.executions == 0
      assert stats.matches == 0
      assert stats.mismatches == 0
      assert stats.crashes == 0
    end

    test "returns error for non-existent shadow" do
      assert {:error, :not_found} = ShadowRunner.get_shadow_stats(NonExistent, :fake)
    end
  end

  describe "get_comparisons/3" do
    test "returns empty list for shadow with no executions" do
      spec = %{
        type: :deterministic,
        code: "code",
        prompt_template: nil,
        provider: nil,
        model: nil,
        created_at: DateTime.utc_now(),
        pattern_description: "test"
      }

      ShadowRunner.register_shadow(CompTest, :pattern, spec)

      comparisons = ShadowRunner.get_comparisons(CompTest, :pattern)
      assert comparisons == []
    end
  end

  describe "get_config/0" do
    test "returns configuration map with expected keys" do
      config = ShadowRunner.get_config()

      assert is_map(config)
      assert Map.has_key?(config, :min_shadow_executions)
      assert Map.has_key?(config, :min_match_rate)
      assert Map.has_key?(config, :max_crash_rate)
      assert Map.has_key?(config, :min_shadow_duration_hours)
    end
  end
end
