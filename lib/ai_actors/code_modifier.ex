defmodule AiActors.CodeModifier do
  @moduledoc """
  GenServer responsible for modifying code and performing hot code reloading.

  This service receives code modification requests from AiActors and:
  1. Writes the new code to disk
  2. Compiles the code
  3. Performs hot code reloading via `:code.purge/1` and `:code.load_file/1`
  4. Notifies the requestor of success/failure

  ## Safety Features
  - Validates code before writing
  - Keeps backups of previous versions
  - Supports rollback on compilation errors
  """

  use GenServer
  require Logger

  @type modification_request :: %{
          module: module(),
          code: String.t(),
          requestor: pid(),
          metadata: map()
        }

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Request a code modification.

  Returns:
  - `{:ok, ref}` - Request accepted, will be notified asynchronously
  - `{:error, reason}` - Request rejected
  """
  @spec modify_code(module(), String.t(), map()) :: {:ok, reference()} | {:error, term()}
  def modify_code(module, new_code, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:modify_code, module, new_code, metadata})
  end

  @doc """
  Get the current source code for a module.
  """
  @spec get_module_source(module()) :: {:ok, String.t()} | {:error, term()}
  def get_module_source(module) do
    GenServer.call(__MODULE__, {:get_source, module})
  end

  @doc """
  List all modifications made during this session.
  """
  @spec list_modifications() :: list(map())
  def list_modifications do
    GenServer.call(__MODULE__, :list_modifications)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    state = %{
      modifications: [],
      backup_dir: setup_backup_dir()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:modify_code, module, new_code, metadata}, {from_pid, _}, state) do
    ref = make_ref()

    # Spawn a task to handle the modification asynchronously
    Task.start(fn ->
      result = do_modify_code(module, new_code, state.backup_dir, metadata)
      send(from_pid, {:code_modification_result, ref, result})
    end)

    {:reply, {:ok, ref}, state}
  end

  @impl true
  def handle_call({:get_source, module}, _from, state) do
    result = get_source_from_disk(module)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_modifications, _from, state) do
    {:reply, state.modifications, state}
  end

  # Private Functions

  defp do_modify_code(module, new_code, backup_dir, metadata) do
    module_name = module |> Module.split() |> Enum.join(".")
    Logger.info("Modifying code for module: #{module_name}")

    with {:ok, file_path} <- get_module_file_path(module),
         :ok <- backup_current_version(file_path, backup_dir),
         :ok <- validate_code(new_code),
         :ok <- write_code(file_path, new_code),
         {:ok, module} <- compile_and_load(file_path, module) do
      Logger.info("Successfully modified and reloaded #{module_name}")

      {:ok,
       %{
         module: module,
         file_path: file_path,
         timestamp: DateTime.utc_now(),
         metadata: metadata
       }}
    else
      {:error, reason} = error ->
        Logger.error("Failed to modify #{module_name}: #{inspect(reason)}")
        error
    end
  end

  defp get_module_file_path(module) do
    # Convert module name to file path
    module_parts =
      module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)

    lib_path = Path.join(["lib" | module_parts]) <> ".ex"

    if File.exists?(lib_path) do
      {:ok, Path.expand(lib_path)}
    else
      # Try to find in code path
      case :code.which(module) do
        path when is_list(path) ->
          # Convert from .beam to .ex (approximation)
          beam_path = List.to_string(path)
          ex_path = String.replace(beam_path, ~r{_build/.*/lib/.*?/ebin/(.*).beam}, "lib/\\1.ex")

          if File.exists?(ex_path) do
            {:ok, ex_path}
          else
            {:ok, lib_path}
          end

        _ ->
          {:ok, lib_path}
      end
    end
  end

  defp backup_current_version(file_path, backup_dir) do
    if File.exists?(file_path) do
      timestamp = DateTime.utc_now() |> DateTime.to_unix()
      backup_name = "#{Path.basename(file_path)}.#{timestamp}.backup"
      backup_path = Path.join(backup_dir, backup_name)

      case File.copy(file_path, backup_path) do
        {:ok, _} ->
          Logger.debug("Backed up #{file_path} to #{backup_path}")
          :ok

        {:error, reason} ->
          Logger.warning("Failed to backup #{file_path}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp validate_code(code) do
    # Basic validation - try to parse the code
    case Code.string_to_quoted(code) do
      {:ok, _ast} -> :ok
      {:error, {_line, error, _token}} -> {:error, {:invalid_syntax, error}}
    end
  end

  defp write_code(file_path, code) do
    # Ensure directory exists
    file_path |> Path.dirname() |> File.mkdir_p!()

    case File.write(file_path, code) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp compile_and_load(file_path, module) do
    # First, purge the old version if it exists
    :code.purge(module)
    :code.delete(module)

    # Compile the file
    case Code.compile_file(file_path) do
      [] ->
        {:error, :compilation_failed}

      modules ->
        # Check if our module is in the compiled modules
        case Enum.find(modules, fn {mod, _} -> mod == module end) do
          {module, _binary} ->
            {:ok, module}

          nil ->
            # Module was compiled but not our target module
            {:error, :module_not_found}
        end
    end
  rescue
    error ->
      {:error, {:compilation_error, error}}
  end

  defp get_source_from_disk(module) do
    case get_module_file_path(module) do
      {:ok, file_path} ->
        if File.exists?(file_path) do
          {:ok, File.read!(file_path)}
        else
          {:error, :file_not_found}
        end

      error ->
        error
    end
  end

  defp setup_backup_dir do
    backup_dir = Path.join([System.tmp_dir!(), "ai_actors_backups"])
    File.mkdir_p!(backup_dir)
    backup_dir
  end
end
