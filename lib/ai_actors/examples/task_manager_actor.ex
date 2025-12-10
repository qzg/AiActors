defmodule AiActors.Examples.TaskManagerActor do
  @moduledoc """
  Example AiActor that manages a list of tasks.

  This actor demonstrates more complex state management and
  custom tool definitions for the LLM.
  """

  use AiActors.AiActor

  # Initialize user state - don't override init, override init_impl
  defp init_impl(_args) do
    {:ok,
     %{
       tasks: [],
       next_id: 1,
       completed_count: 0
     }}
  end

  @impl AiActors.AiActor
  def development_metadata do
    %{
      purpose: "Manage a task list with create, complete, and query operations",
      design_decisions: [
        "Use auto-incrementing IDs for tasks",
        "Track completion count for metrics",
        "Allow natural language queries via LLM"
      ],
      dependencies: ["AiActors.LLMClient"],
      created_at: ~U[2025-01-15 00:00:00Z],
      version: "1.0.0",
      custom_metadata: %{
        features: ["task_creation", "task_completion", "natural_language_search"]
      }
    }
  end

  @impl AiActors.AiActor
  def available_tools do
    AiActors.AiActor.default_tools() ++
      [
        %{
          name: "create_task",
          description: "Create a new task",
          input_schema: %{
            type: "object",
            properties: %{
              title: %{type: "string", description: "Task title"},
              description: %{type: "string", description: "Task description"},
              priority: %{
                type: "string",
                enum: ["low", "medium", "high"],
                description: "Task priority"
              }
            },
            required: ["title"]
          }
        },
        %{
          name: "complete_task",
          description: "Mark a task as completed",
          input_schema: %{
            type: "object",
            properties: %{
              task_id: %{type: "integer", description: "ID of the task to complete"}
            },
            required: ["task_id"]
          }
        },
        %{
          name: "list_tasks",
          description: "List all tasks, optionally filtered",
          input_schema: %{
            type: "object",
            properties: %{
              status: %{
                type: "string",
                enum: ["all", "pending", "completed"],
                description: "Filter by status"
              }
            }
          }
        },
        %{
          name: "search_tasks",
          description: "Search tasks by keyword",
          input_schema: %{
            type: "object",
            properties: %{
              keyword: %{type: "string", description: "Search keyword"}
            },
            required: ["keyword"]
          }
        }
      ]
  end

  @impl AiActors.AiActor
  def execute_tool("create_task", input, state) do
    task = %{
      id: state.user_state.next_id,
      title: input["title"],
      description: input["description"],
      priority: input["priority"] || "medium",
      status: :pending,
      created_at: DateTime.utc_now(),
      completed_at: nil
    }

    new_user_state = %{
      state.user_state
      | tasks: state.user_state.tasks ++ [task],
        next_id: state.user_state.next_id + 1
    }

    {:ok, task, %{state | user_state: new_user_state}}
  end

  def execute_tool("complete_task", %{"task_id" => task_id}, state) do
    case Enum.find_index(state.user_state.tasks, &(&1.id == task_id)) do
      nil ->
        {:error, :task_not_found}

      index ->
        task = Enum.at(state.user_state.tasks, index)
        updated_task = %{task | status: :completed, completed_at: DateTime.utc_now()}
        updated_tasks = List.replace_at(state.user_state.tasks, index, updated_task)

        new_user_state = %{
          state.user_state
          | tasks: updated_tasks,
            completed_count: state.user_state.completed_count + 1
        }

        {:ok, updated_task, %{state | user_state: new_user_state}}
    end
  end

  def execute_tool("list_tasks", input, state) do
    status_filter = input["status"] || "all"

    filtered_tasks =
      case status_filter do
        "all" -> state.user_state.tasks
        "pending" -> Enum.filter(state.user_state.tasks, &(&1.status == :pending))
        "completed" -> Enum.filter(state.user_state.tasks, &(&1.status == :completed))
        _ -> state.user_state.tasks
      end

    {:ok, filtered_tasks, state}
  end

  def execute_tool("search_tasks", %{"keyword" => keyword}, state) do
    keyword_lower = String.downcase(keyword)

    matching_tasks =
      Enum.filter(state.user_state.tasks, fn task ->
        String.contains?(String.downcase(task.title), keyword_lower) or
          (task.description &&
             String.contains?(String.downcase(task.description), keyword_lower))
      end)

    {:ok, matching_tasks, state}
  end

  def execute_tool(tool_name, input, state) do
    # Delegate to default tools
    AiActors.AiActor.execute_default_tool(tool_name, input, state, __MODULE__)
  end

  # Public API

  def create_task(server, title, description \\ nil, priority \\ "medium") do
    GenServer.call(server, {:create_task, title, description, priority})
  end

  def complete_task(server, task_id) do
    GenServer.call(server, {:complete_task, task_id})
  end

  def list_tasks(server, status \\ :all) do
    GenServer.call(server, {:list_tasks, status})
  end

  # Message handlers - use handle_call_impl to work with framework

  defp handle_call_impl({:create_task, title, description, priority}, _from, state) do
    task = %{
      id: state.next_id,
      title: title,
      description: description,
      priority: priority,
      status: :pending,
      created_at: DateTime.utc_now(),
      completed_at: nil
    }

    new_state = %{
      state
      | tasks: state.tasks ++ [task],
        next_id: state.next_id + 1
    }

    {:reply, {:ok, task}, new_state}
  end

  defp handle_call_impl({:complete_task, task_id}, _from, state) do
    case Enum.find_index(state.tasks, &(&1.id == task_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      index ->
        task = Enum.at(state.tasks, index)
        updated_task = %{task | status: :completed, completed_at: DateTime.utc_now()}
        updated_tasks = List.replace_at(state.tasks, index, updated_task)

        new_state = %{
          state
          | tasks: updated_tasks,
            completed_count: state.completed_count + 1
        }

        {:reply, {:ok, updated_task}, new_state}
    end
  end

  defp handle_call_impl({:list_tasks, status}, _from, state) do
    filtered_tasks =
      case status do
        :all -> state.tasks
        :pending -> Enum.filter(state.tasks, &(&1.status == :pending))
        :completed -> Enum.filter(state.tasks, &(&1.status == :completed))
      end

    {:reply, filtered_tasks, state}
  end

  # Escalate unknown messages to LLM
  defp handle_call_impl(_msg, _from, _state) do
    :escalate_to_llm
  end

  defp handle_cast_impl(_msg, state) do
    {:noreply, state}
  end

  defp handle_info_impl(_msg, state) do
    {:noreply, state}
  end
end
