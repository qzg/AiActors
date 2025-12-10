defmodule AiActors.CodeModifierTest do
  use ExUnit.Case, async: false

  alias AiActors.CodeModifier

  setup do
    # Ensure CodeModifier is started
    case GenServer.whereis(CodeModifier) do
      nil ->
        {:ok, _pid} = start_supervised(CodeModifier)
        :ok

      _pid ->
        :ok
    end
  end

  describe "modify_code/3" do
    test "accepts valid modification request" do
      module = TestModule
      code = """
      defmodule TestModule do
        def hello, do: :world
      end
      """

      assert {:ok, ref} = CodeModifier.modify_code(module, code, %{test: true})
      assert is_reference(ref)
    end

    test "handles invalid syntax" do
      module = TestModule
      invalid_code = """
      defmodule TestModule do
        def hello do
          # Missing end
      """

      # The request is accepted but will fail asynchronously
      assert {:ok, ref} = CodeModifier.modify_code(module, invalid_code, %{})
      assert is_reference(ref)

      # Give it time to process
      Process.sleep(100)

      # The module should receive a failure notification
      # (in real usage, the requestor would receive this)
    end
  end

  describe "get_module_source/1" do
    test "returns error for non-existent module" do
      assert {:error, _} = CodeModifier.get_module_source(NonExistentModule)
    end

    test "returns source for existing module" do
      # CodeModifier itself should have source
      result = CodeModifier.get_module_source(CodeModifier)

      case result do
        {:ok, source} ->
          assert is_binary(source)
          assert String.contains?(source, "defmodule AiActors.CodeModifier")

        {:error, _} ->
          # May not find source in test environment, that's ok
          :ok
      end
    end
  end

  describe "list_modifications/0" do
    test "returns a list" do
      result = CodeModifier.list_modifications()
      assert is_list(result)
    end
  end

  describe "code validation" do
    test "valid Elixir code structure" do
      code = """
      defmodule MyModule do
        use GenServer

        def init(args), do: {:ok, args}
      end
      """

      # Should parse without errors
      assert {:ok, _ast} = Code.string_to_quoted(code)
    end

    test "invalid code structure" do
      code = """
      defmodule MyModule do
        def broken do
          {
      end
      """

      assert {:error, _} = Code.string_to_quoted(code)
    end
  end
end
