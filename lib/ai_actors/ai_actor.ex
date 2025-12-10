defmodule AiActors.AiActor do
  @moduledoc """
  An intelligent GenServer that leverages LLM capabilities to handle messages.

  ## Key Features

  1. **Development Context Tracking**: Maintains metadata about implementation decisions,
     design rationale, and development history.

  2. **LLM Integration**: Can delegate message handling to an associated LLM when needed.

  3. **Self-Modification**: Can request changes to its own code through the CodeModifier.

  4. **Tool System**: Provides tools that the LLM can call to interact with the system.

  5. **Unhandled Message Escalation**: Automatically escalates unhandled messages to the LLM.

  ## Usage

  To create an AiActor, implement your module and `use AiActors.AiActor`:

      defmodule MyApp.MyActor do
        use AiActors.AiActor

        @impl true
        def init(args) do
          state = %{
            counter: 0,
            data: []
          }
          {:ok, state}
        end

        @impl true
        def handle_call({:increment, amount}, _from, state) do
          new_state = %{state | counter: state.counter + amount}
          {:reply, new_state.counter, new_state}
        end

        # Unhandled messages will be escalated to LLM automatically
      end

  ## Development Metadata

  Each AiActor maintains metadata about its implementation:

  - `:purpose` - High-level description of what this actor does
  - `:design_decisions` - List of key architectural/design choices
  - `:dependencies` - Other modules/services this actor depends on
  - `:created_at` - When this actor was created
  - `:modified_at` - When this actor was last modified
  - `:version` - Current version number
  - `:custom_metadata` - Module-specific metadata

  """

  @type t :: %{
          __struct__: module(),
          llm_messages: list(),
          development_metadata: map(),
          conversation_history: list(),
          available_tools: list(),
          pending_modifications: map()
        }

  @doc """
  Invoked when the AiActor is started.
  Similar to GenServer.init/1 but with AiActor extensions.
  """
  @callback init(args :: term()) :: {:ok, state :: term()} | {:stop, reason :: term()}

  @doc """
  Defines the development metadata for this actor.
  This metadata helps the LLM understand the actor's purpose and implementation.
  """
  @callback development_metadata() :: map()

  @doc """
  Defines tools available to the LLM for this actor.
  """
  @callback available_tools() :: list()

  @doc """
  Handles tool execution requests from the LLM.
  """
  @callback execute_tool(tool_name :: String.t(), input :: map(), state :: term()) ::
              {:ok, result :: term(), new_state :: term()} | {:error, reason :: term()}

  @doc """
  Whether this actor should enable self-learning capabilities.
  """
  @callback enable_self_learning?() :: boolean()

  @doc """
  Configuration for self-learning behavior.
  """
  @callback self_learning_config() :: map()

  @optional_callbacks development_metadata: 0, available_tools: 0, execute_tool: 3,
                      enable_self_learning?: 0, self_learning_config: 0

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour AiActors.AiActor
      @before_compile AiActors.AiActor

      require Logger

      # Default implementations

      @impl AiActors.AiActor
      def development_metadata do
        %{
          purpose: "No purpose defined",
          design_decisions: [],
          dependencies: [],
          created_at: DateTime.utc_now(),
          version: "0.1.0"
        }
      end

      @impl AiActors.AiActor
      def available_tools do
        AiActors.AiActor.default_tools()
      end

      @impl AiActors.AiActor
      def execute_tool(tool_name, input, state) do
        AiActors.AiActor.execute_default_tool(tool_name, input, state, __MODULE__)
      end

      @impl AiActors.AiActor
      def enable_self_learning?, do: false

      @impl AiActors.AiActor
      def self_learning_config, do: %{}

      defoverridable development_metadata: 0, available_tools: 0, execute_tool: 3,
                     enable_self_learning?: 0, self_learning_config: 0

      # Wrap init to add AiActor extensions
      def start_link(args, opts \\ []) do
        GenServer.start_link(__MODULE__, args, opts)
      end

      @doc """
      Ask the LLM to handle a message and generate a response.
      """
      def ask_llm(server, prompt, context \\ %{}) do
        GenServer.call(server, {:__ai_actor_ask_llm__, prompt, context})
      end

      @doc """
      Request a modification to this actor's code.
      """
      def request_code_modification(server, modification_request) do
        GenServer.call(server, {:__ai_actor_modify_code__, modification_request})
      end

      @doc """
      Get the actor's development metadata.
      """
      def get_metadata(server) do
        GenServer.call(server, :__ai_actor_get_metadata__)
      end

      @doc """
      Trigger a self-learning review for this actor.
      """
      def trigger_review(server) do
        GenServer.call(server, :__ai_actor_trigger_review__, 60_000)
      end

      @doc """
      Get learning statistics for this actor.
      """
      def get_learning_stats(server) do
        GenServer.call(server, :__ai_actor_learning_stats__)
      end

      # Internal GenServer implementation with AiActor extensions

      @doc false
      def init(args) do
        case init_impl(args) do
          {:ok, user_state} ->
            ai_state = %{
              user_state: user_state,
              llm_messages: [],
              development_metadata: development_metadata(),
              conversation_history: [],
              available_tools: available_tools(),
              pending_modifications: %{},
              self_learning_timer: nil
            }

            # Start self-learning if enabled
            ai_state =
              if enable_self_learning?() do
                case AiActors.SelfLearning.start_learning(self(), __MODULE__) do
                  {:ok, timer_ref} ->
                    Logger.info("Self-learning enabled for #{inspect(__MODULE__)}")
                    %{ai_state | self_learning_timer: timer_ref}

                  {:error, reason} ->
                    Logger.warning("Failed to start self-learning: #{inspect(reason)}")
                    ai_state
                end
              else
                ai_state
              end

            {:ok, ai_state}

          other ->
            other
        end
      end

      # Users MUST define init_impl/1 to initialize their state

      @doc false
      def handle_call({:__ai_actor_ask_llm__, prompt, context}, from, state) do
        AiActors.AiActor.handle_llm_request(prompt, context, state, __MODULE__, from)
      end

      @doc false
      def handle_call({:__ai_actor_modify_code__, modification_request}, _from, state) do
        AiActors.AiActor.handle_code_modification_request(
          modification_request,
          state,
          __MODULE__
        )
      end

      @doc false
      def handle_call(:__ai_actor_get_metadata__, _from, state) do
        {:reply, state.development_metadata, state}
      end

      @doc false
      def handle_call(:__ai_actor_trigger_review__, _from, state) do
        result = AiActors.SelfLearning.perform_review(__MODULE__)
        {:reply, result, state}
      end

      @doc false
      def handle_call(:__ai_actor_learning_stats__, _from, state) do
        stats = AiActors.EscalationTracker.get_statistics(__MODULE__)
        report = AiActors.SelfLearning.generate_report(__MODULE__)
        {:reply, %{statistics: stats, report: report}, state}
      end

      # Intercept handle_call to provide LLM escalation
      @doc false
      def handle_call(msg, from, state) do
        case handle_call_impl(msg, from, state.user_state) do
          {:reply, reply, new_user_state} ->
            {:reply, reply, %{state | user_state: new_user_state}}

          {:noreply, new_user_state} ->
            {:noreply, %{state | user_state: new_user_state}}

          {:stop, reason, reply, new_user_state} ->
            {:stop, reason, reply, %{state | user_state: new_user_state}}

          {:stop, reason, new_user_state} ->
            {:stop, reason, %{state | user_state: new_user_state}}

          :escalate_to_llm ->
            # Escalate to LLM
            AiActors.AiActor.escalate_to_llm(:call, msg, state, __MODULE__, from)

          other ->
            other
        end
      end

      # Users must define handle_call_impl/3 - no default provided

      @doc false
      def handle_cast(msg, state) do
        case handle_cast_impl(msg, state.user_state) do
          {:noreply, new_user_state} ->
            {:noreply, %{state | user_state: new_user_state}}

          {:stop, reason, new_user_state} ->
            {:stop, reason, %{state | user_state: new_user_state}}

          :escalate_to_llm ->
            AiActors.AiActor.escalate_to_llm(:cast, msg, state, __MODULE__, nil)

          other ->
            other
        end
      end

      # Users must define handle_cast_impl/2 - no default provided

      @doc false
      def handle_info({:code_modification_result, ref, result}, state) do
        case Map.get(state.pending_modifications, ref) do
          nil ->
            {:noreply, state}

          _request ->
            Logger.info("Code modification result: #{inspect(result)}")

            new_pending = Map.delete(state.pending_modifications, ref)

            case result do
              {:ok, _info} ->
                # Successfully modified - the module will be reloaded
                # Update metadata
                new_metadata =
                  Map.put(state.development_metadata, :modified_at, DateTime.utc_now())

                {:noreply,
                 %{
                   state
                   | pending_modifications: new_pending,
                     development_metadata: new_metadata
                 }}

              {:error, reason} ->
                Logger.error("Code modification failed: #{inspect(reason)}")
                {:noreply, %{state | pending_modifications: new_pending}}
            end
        end
      end

      @doc false
      def handle_info({:self_learning_review, actor_module}, state) do
        # Perform periodic self-learning review
        Logger.info("Performing scheduled self-learning review for #{inspect(actor_module)}")

        Task.start(fn ->
          AiActors.SelfLearning.perform_review(actor_module)
        end)

        # Reschedule next review
        if enable_self_learning?() do
          case AiActors.SelfLearning.start_learning(self(), __MODULE__) do
            {:ok, timer_ref} ->
              {:noreply, %{state | self_learning_timer: timer_ref}}

            {:error, _reason} ->
              {:noreply, state}
          end
        else
          {:noreply, state}
        end
      end

      @doc false
      def handle_info(msg, state) do
        case handle_info_impl(msg, state.user_state) do
          {:noreply, new_user_state} ->
            {:noreply, %{state | user_state: new_user_state}}

          {:stop, reason, new_user_state} ->
            {:stop, reason, %{state | user_state: new_user_state}}

          :escalate_to_llm ->
            AiActors.AiActor.escalate_to_llm(:info, msg, state, __MODULE__, nil)

          other ->
            other
        end
      end

      # Users must define handle_info_impl/2 - no default provided

      # Allow the module to override our init wrapper
      defoverridable init: 1, handle_call: 3, handle_cast: 2, handle_info: 2
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Check if the user module defines handle_call/3
    if Module.defines?(env.module, {:handle_call, 3}, :def) do
      # Check if it's actually overriding our implementation (not just from GenServer)
      quote do
        require Logger

        Logger.warning("""
        #{__MODULE__} overrides handle_call/3 directly, which may break AiActor framework features.

        To fix:
        1. Rename your handle_call/3 clauses to handle_call_impl/3
        2. Make them private (defp instead of def)
        3. The framework will call your handle_call_impl/3 automatically

        Example:
          # Instead of:
          def handle_call({:increment, n}, _from, state) do
            {:reply, n, state}
          end

          # Use:
          defp handle_call_impl({:increment, n}, _from, state) do
            {:reply, n, state}
          end

        See WARP.md for more details.
        """)
      end
    else
      quote do
      end
    end
  end

  # Public API for runtime behavior

  @doc """
  Default tools available to all AiActors.
  """
  def default_tools do
    [
      %{
        name: "get_state",
        description: "Get the current state of the actor",
        input_schema: %{
          type: "object",
          properties: %{},
          required: []
        }
      },
      %{
        name: "update_state",
        description: "Update the actor's state with new values",
        input_schema: %{
          type: "object",
          properties: %{
            updates: %{
              type: "object",
              description: "Map of state keys to update"
            }
          },
          required: ["updates"]
        }
      },
      %{
        name: "request_code_change",
        description: "Request a modification to this actor's code",
        input_schema: %{
          type: "object",
          properties: %{
            reason: %{
              type: "string",
              description: "Why this code change is needed"
            },
            changes: %{
              type: "string",
              description: "Description of the changes to make"
            }
          },
          required: ["reason", "changes"]
        }
      },
      %{
        name: "get_metadata",
        description: "Get development metadata about this actor",
        input_schema: %{
          type: "object",
          properties: %{},
          required: []
        }
      }
    ]
  end

  @doc """
  Execute a default tool.
  """
  def execute_default_tool("get_state", _input, state, _module) do
    {:ok, state.user_state, state}
  end

  def execute_default_tool("update_state", %{"updates" => updates}, state, _module) do
    new_user_state = Map.merge(state.user_state, updates)
    {:ok, %{success: true, new_state: new_user_state}, %{state | user_state: new_user_state}}
  end

  def execute_default_tool("request_code_change", input, state, module) do
    %{"reason" => reason, "changes" => changes} = input

    # Build a prompt for the LLM to generate the new code
    prompt = """
    I need to modify the code for module #{inspect(module)}.

    Reason: #{reason}
    Requested changes: #{changes}

    Current metadata: #{inspect(state.development_metadata)}

    Please generate the complete updated Elixir module code.
    """

    case AiActors.LLMClient.send_message(
           [%{role: "user", content: prompt}],
           system: "You are a code generation assistant. Generate valid Elixir code.",
           max_tokens: 8000
         ) do
      {:ok, %{"content" => content}} ->
        new_code = extract_code_from_response(content)

        case AiActors.CodeModifier.modify_code(module, new_code, %{
               reason: reason,
               changes: changes
             }) do
          {:ok, ref} ->
            new_pending = Map.put(state.pending_modifications, ref, %{
              reason: reason,
              changes: changes,
              requested_at: DateTime.utc_now()
            })

            {:ok, %{success: true, modification_ref: ref},
             %{state | pending_modifications: new_pending}}

          {:error, reason} ->
            {:error, {:code_modification_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:llm_request_failed, reason}}
    end
  end

  def execute_default_tool("get_metadata", _input, state, _module) do
    {:ok, state.development_metadata, state}
  end

  def execute_default_tool(tool_name, _input, state, _module) do
    {:error, {:unknown_tool, tool_name}}
  end

  @doc """
  Handle an LLM request from the actor.
  """
  def handle_llm_request(prompt, context, state, module, from) do
    # Build the system prompt with actor context
    system_prompt = build_system_prompt(state, module, context)

    # Add the new message to conversation
    messages = state.llm_messages ++ [%{role: "user", content: prompt}]

    # Define tool executor
    tool_executor = fn tool_name, input ->
      case module.execute_tool(tool_name, input, state) do
        {:ok, result, _new_state} -> result
        {:error, reason} -> %{error: inspect(reason)}
      end
    end

    # Send to LLM with tools
    Task.start(fn ->
      result =
        AiActors.LLMClient.send_message_with_tools(
          messages,
          state.available_tools,
          [system: system_prompt],
          tool_executor
        )

      GenServer.reply(from, result)
    end)

    {:noreply, %{state | llm_messages: messages}}
  end

  @doc """
  Handle a code modification request.
  """
  def handle_code_modification_request(modification_request, state, module) do
    case AiActors.CodeModifier.modify_code(
           module,
           modification_request.new_code,
           modification_request.metadata || %{}
         ) do
      {:ok, ref} ->
        new_pending = Map.put(state.pending_modifications, ref, modification_request)
        {:reply, {:ok, ref}, %{state | pending_modifications: new_pending}}

      error ->
        {:reply, error, state}
    end
  end

  @doc """
  Escalate an unhandled message to the LLM.
  """
  def escalate_to_llm(message_type, message, state, module, from) do
    require Logger

    Logger.info(
      "Escalating #{message_type} message to LLM: #{inspect(message)} for #{inspect(module)}"
    )

    # Build a prompt describing the message
    prompt = """
    I received a #{message_type} message that I don't know how to handle:
    #{inspect(message, pretty: true)}

    My current state is:
    #{inspect(state.user_state, pretty: true)}

    How should I respond? Please provide a response in JSON format with:
    {
      "action": "reply" | "noreply" | "error",
      "value": <the reply value or error reason>,
      "state_updates": <optional map of state updates>
    }
    """

    system_prompt = build_system_prompt(state, module, %{message_type: message_type})

    # Query LLM asynchronously if this is a call
    if message_type == :call and from do
      Task.start(fn ->
        start_time = System.monotonic_time(:millisecond)

        result =
          AiActors.LLMClient.send_message(
            [%{role: "user", content: prompt}],
            system: system_prompt,
            structured_output: %{
              type: "object",
              properties: %{
                action: %{
                  type: "string",
                  enum: ["reply", "noreply", "error"],
                  description: "The type of response to provide"
                },
                value: %{
                  type: "string",
                  description: "The reply value (as JSON string) or error reason"
                },
                state_updates: %{
                  type: "object",
                  description: "Map of state updates to apply",
                  additionalProperties: true
                }
              },
              required: ["action"]
            }
          )

        end_time = System.monotonic_time(:millisecond)
        execution_time = end_time - start_time

        response =
          case result do
            {:ok, llm_response} ->
              case AiActors.LLMClient.parse_structured_response(llm_response) do
                {:ok, parsed} ->
                  # Log successful escalation
                  AiActors.EscalationTracker.log_escalation(
                    module,
                    self(),
                    message,
                    message_type,
                    parsed,
                    execution_time
                  )

                  {:ok, parsed}

                error ->
                  # Log failed escalation
                  AiActors.EscalationTracker.log_escalation(
                    module,
                    self(),
                    message,
                    message_type,
                    {:error, :invalid_llm_response},
                    execution_time
                  )

                  {:error, :invalid_llm_response}
              end

            error ->
              # Log error
              AiActors.EscalationTracker.log_escalation(
                module,
                self(),
                message,
                message_type,
                error,
                execution_time
              )

              error
          end

        GenServer.reply(from, response)
      end)

      {:noreply, state}
    else
      # For cast/info, just log
      Logger.info("Cannot escalate #{message_type} to LLM (no synchronous response expected)")
      {:noreply, state}
    end
  end

  # Private helpers

  defp build_system_prompt(state, module, context) do
    """
    You are an AI assistant helping to operate an intelligent actor (GenServer) in an Elixir system.

    Module: #{inspect(module)}

    Development Metadata:
    #{inspect(state.development_metadata, pretty: true)}

    Current State:
    #{inspect(state.user_state, pretty: true)}

    Context:
    #{inspect(context, pretty: true)}

    You have access to tools to interact with the actor's state and request code modifications.
    Always think carefully about the request and provide helpful, accurate responses.
    """
  end

  defp extract_code_from_response(content) do
    text =
      content
      |> Enum.filter(&is_map(&1) and Map.get(&1, "type") == "text")
      |> Enum.map(&Map.get(&1, "text"))
      |> Enum.join("\n")

    # Try to extract code from markdown code blocks
    case Regex.run(~r/```(?:elixir)?\n(.*?)\n```/s, text) do
      [_, code] -> code
      nil -> text
    end
  end
end
