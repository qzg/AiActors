defmodule AiActors.AiActorTest do
  use ExUnit.Case, async: false

  alias AiActors.Examples.CounterActor
  alias AiActors.Examples.TaskManagerActor

  setup do
    # Ensure required services are running
    start_supervised!(AiActors.CodeModifier)
    :ok
  end

  describe "CounterActor" do
    test "initializes with default value" do
      {:ok, pid} = CounterActor.start_link(0)
      assert Process.alive?(pid)

      value = GenServer.call(pid, :get_value)
      assert value == 0

      GenServer.stop(pid)
    end

    test "initializes with custom value" do
      {:ok, pid} = CounterActor.start_link(10)

      value = GenServer.call(pid, :get_value)
      assert value == 10

      GenServer.stop(pid)
    end

    test "increments counter" do
      {:ok, pid} = CounterActor.start_link(0)

      assert 5 == GenServer.call(pid, {:increment, 5})
      assert 15 == GenServer.call(pid, {:increment, 10})
      assert 15 == GenServer.call(pid, :get_value)

      GenServer.stop(pid)
    end

    test "decrements counter" do
      {:ok, pid} = CounterActor.start_link(20)

      assert 15 == GenServer.call(pid, {:decrement, 5})
      assert 5 == GenServer.call(pid, {:decrement, 10})
      assert 5 == GenServer.call(pid, :get_value)

      GenServer.stop(pid)
    end

    test "maintains history" do
      {:ok, pid} = CounterActor.start_link(0)

      GenServer.call(pid, {:increment, 5})
      GenServer.call(pid, {:decrement, 2})
      GenServer.call(pid, {:increment, 10})

      history = GenServer.call(pid, :get_history)

      assert length(history) == 3
      assert Enum.at(history, 0).operation == :increment
      assert Enum.at(history, 1).operation == :decrement
      assert Enum.at(history, 2).operation == :increment

      GenServer.stop(pid)
    end

    test "has development metadata" do
      {:ok, pid} = CounterActor.start_link(0)

      metadata = CounterActor.get_metadata(pid)

      assert is_map(metadata)
      assert metadata.purpose =~ "counter"
      assert is_list(metadata.design_decisions)
      assert metadata.version == "1.0.0"

      GenServer.stop(pid)
    end
  end

  describe "TaskManagerActor" do
    test "initializes with empty task list" do
      {:ok, pid} = TaskManagerActor.start_link([])

      tasks = TaskManagerActor.list_tasks(pid)
      assert tasks == []

      GenServer.stop(pid)
    end

    test "creates tasks" do
      {:ok, pid} = TaskManagerActor.start_link([])

      {:ok, task} = TaskManagerActor.create_task(pid, "Buy groceries", "Get milk and eggs")

      assert task.id == 1
      assert task.title == "Buy groceries"
      assert task.description == "Get milk and eggs"
      assert task.status == :pending

      GenServer.stop(pid)
    end

    test "completes tasks" do
      {:ok, pid} = TaskManagerActor.start_link([])

      {:ok, task} = TaskManagerActor.create_task(pid, "Task 1")
      assert task.status == :pending

      {:ok, completed_task} = TaskManagerActor.complete_task(pid, task.id)
      assert completed_task.status == :completed
      assert completed_task.completed_at != nil

      GenServer.stop(pid)
    end

    test "lists tasks by status" do
      {:ok, pid} = TaskManagerActor.start_link([])

      {:ok, task1} = TaskManagerActor.create_task(pid, "Task 1")
      {:ok, task2} = TaskManagerActor.create_task(pid, "Task 2")
      {:ok, _task3} = TaskManagerActor.create_task(pid, "Task 3")

      TaskManagerActor.complete_task(pid, task1.id)

      pending_tasks = TaskManagerActor.list_tasks(pid, :pending)
      assert length(pending_tasks) == 2

      completed_tasks = TaskManagerActor.list_tasks(pid, :completed)
      assert length(completed_tasks) == 1

      all_tasks = TaskManagerActor.list_tasks(pid, :all)
      assert length(all_tasks) == 3

      GenServer.stop(pid)
    end

    test "has custom tools" do
      tools = TaskManagerActor.available_tools()

      assert is_list(tools)
      assert length(tools) > 4

      tool_names = Enum.map(tools, & &1.name)
      assert "create_task" in tool_names
      assert "complete_task" in tool_names
      assert "list_tasks" in tool_names
      assert "search_tasks" in tool_names
    end
  end

  describe "AiActor behavior" do
    test "default tools are available" do
      tools = AiActors.AiActor.default_tools()

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1.name)

      assert "get_state" in tool_names
      assert "update_state" in tool_names
      assert "get_metadata" in tool_names
      assert "request_code_change" in tool_names
    end

    test "tool schemas are valid" do
      tools = AiActors.AiActor.default_tools()

      Enum.each(tools, fn tool ->
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.input_schema.type == "object"
      end)
    end
  end
end
