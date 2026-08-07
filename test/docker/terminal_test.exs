defmodule Docker.TerminalTest do
  use ExUnit.Case

  alias Docker.Terminal

  @dockerfile "Dockerfile"
  @context_path "examples/terminal-example"

  setup_all do
    image_tag = "docker-terminal-test-repl:#{System.unique_integer([:positive])}"

    {:ok, build_events} = Docker.build_image(@context_path, @dockerfile, image_tag)
    Enum.each(build_events, fn _ -> :ok end)

    on_exit(fn -> Docker.delete_image(image_tag, %{}) end)

    {:ok, %{image_tag: image_tag}}
  end

  describe "unregistered names (no Docker required)" do
    test "command/3 returns a :not_found error when no session is open" do
      name = "unregistered-#{System.unique_integer([:positive])}"

      assert {:error, %ErrorMessage{code: :not_found, details: details}} =
               Terminal.command(name, "echo hi")

      assert %{container_ref: ^name} = details
    end

    test "close/1 of an unregistered name is :ok" do
      name = "unregistered-#{System.unique_integer([:positive])}"
      assert :ok = Terminal.close(name)
    end

    test "whereis/1 of an unregistered name is a :not_found error" do
      name = "unregistered-#{System.unique_integer([:positive])}"

      assert {:error, %ErrorMessage{code: :not_found, details: %{container_ref: ^name}}} =
               Terminal.whereis(name)
    end
  end

  describe "open/2 + command/3 + close/1 against a real daemon" do
    test "open / command / close round-trips through the registered session",
         %{image_tag: image_tag} do
      container_name = "term-name-#{System.unique_integer([:positive])}"

      {:ok, _id} = Docker.create_container("docker-test", container_name, image_tag, %{})
      on_exit(fn -> Docker.delete_container(container_name, %{force: true}) end)
      {:ok, _} = Docker.start_container(container_name)

      assert :ok = Terminal.open(container_name, shell: ["/repl.sh"])

      assert {:ok, pid} = Terminal.whereis(container_name)
      assert is_pid(pid)
      monitor_ref = Process.monitor(pid)

      assert {:ok, {reply1, ^container_name}} = Terminal.command(container_name, "ping")
      assert String.contains?(reply1, "got: ping")

      assert {:ok, {reply2, ^container_name}} = Terminal.command(container_name, "pong")
      assert String.contains?(reply2, "got: pong")

      assert :ok = Terminal.close(container_name)
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _}, 1_000
      assert {:error, %ErrorMessage{code: :not_found}} = Terminal.whereis(container_name)
    end

    test "open/2 twice for the same name returns a :conflict error",
         %{image_tag: image_tag} do
      container_name = "term-dup-#{System.unique_integer([:positive])}"

      {:ok, _id} = Docker.create_container("docker-test", container_name, image_tag, %{})
      on_exit(fn -> Docker.delete_container(container_name, %{force: true}) end)
      {:ok, _} = Docker.start_container(container_name)

      assert :ok = Terminal.open(container_name, shell: ["/repl.sh"])

      assert {:error, %ErrorMessage{code: :conflict, details: details}} =
               Terminal.open(container_name, shell: ["/repl.sh"])

      assert %{container_ref: ^container_name, pid: pid} = details
      assert is_pid(pid)

      assert :ok = Terminal.close(container_name)
    end

    test "open/2 defaults set at open time apply to every command",
         %{image_tag: image_tag} do
      container_name = "term-defaults-#{System.unique_integer([:positive])}"

      {:ok, _id} = Docker.create_container("docker-test", container_name, image_tag, %{})
      on_exit(fn -> Docker.delete_container(container_name, %{force: true}) end)
      {:ok, _} = Docker.start_container(container_name)

      assert :ok =
               Terminal.open(container_name,
                 shell: ["/repl.sh"],
                 recv_mode: {:idle_timeout, 500}
               )

      assert {:ok, {reply, ^container_name}} = Terminal.command(container_name, "hi")
      assert String.contains?(reply, "got: hi")

      assert :ok = Terminal.close(container_name)
    end
  end
end
