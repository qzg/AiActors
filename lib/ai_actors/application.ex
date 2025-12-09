defmodule AiActors.Application do
  @moduledoc """
  The AiActors Application.

  Supervises the core infrastructure including the CodeModifier service.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Core services
      AiActors.CodeModifier,

      # Dynamic supervisor for AiActors
      {DynamicSupervisor, strategy: :one_for_one, name: AiActors.ActorSupervisor}
    ]

    opts = [strategy: :one_for_one, name: AiActors.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
