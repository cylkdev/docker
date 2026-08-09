defmodule Docker.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Docker.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Docker.DynamicSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Docker.Supervisor)
  end
end
