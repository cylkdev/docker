defmodule DaemonCase do
  @moduledoc """
  Case template for tests that drive the public API against a real docker
  daemon.

  Real-daemon tests share the daemon, so they are never async. Every helper
  here registers its own cleanup, so a failing test does not leave containers
  behind for the next run.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      import DaemonCase

      @image "alpine:3.19"
    end
  end

  @doc "A name no other test will collide with."
  def unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Creates a container running `cmd` and returns its id. The container is
  deleted when the test ends, whether it passed or failed.
  """
  def create_container!(cmd, opts \\ []) do
    name = unique_name("docker-ex-test")

    {:ok, id} =
      Docker.create_container(
        "docker-ex-test",
        name,
        "alpine:3.19",
        %{},
        Keyword.put_new(opts, :cmd, cmd)
      )

    ExUnit.Callbacks.on_exit(fn ->
      Docker.delete_container(id, %{force: true})
    end)

    id
  end

  @doc "Creates a container, starts it, and returns its id."
  def start_container!(cmd, opts \\ []) do
    id = create_container!(cmd, opts)
    {:ok, _} = Docker.start_container(id)
    id
  end
end
