defmodule Docker.TerminalTest do
  use ExUnit.Case

  alias Docker.Sandbox
  alias Docker.Terminal

  @sandbox [sandbox: [enabled: true]]

  @dockerfile "examples/terminal-example/Dockerfile"
  @context_path "examples/terminal-example"

  setup_all do
    image_tag = "docker-terminal-test-repl:#{System.unique_integer([:positive])}"

    {:ok, build_events} = Docker.build_image(@context_path, @dockerfile, image_tag)
    Enum.each(build_events, fn _ -> :ok end)

    on_exit(fn -> Docker.delete_image(image_tag, %{}) end)

    {:ok, %{image_tag: image_tag}}
  end

  describe "run/3 (sandboxed)" do
    test "runs a string command, wrapping it under /bin/sh -c" do
      Sandbox.set_exec_run_responses([
        {~r/.*/, fn _ref, cmd -> {:ok, "wrapped:#{inspect(cmd)}"} end}
      ])

      assert {:ok, "wrapped:" <> rest} = Terminal.run("c1", "echo hello", @sandbox)
      assert rest == inspect(["/bin/sh", "-c", "echo hello"])
    end

    test "passes an argv list through verbatim" do
      Sandbox.set_exec_run_responses([
        {~r/.*/, fn _ref, cmd -> {:ok, "raw:#{inspect(cmd)}"} end}
      ])

      assert {:ok, "raw:" <> rest} = Terminal.run("c1", ["ls", "/etc"], @sandbox)
      assert rest == inspect(["ls", "/etc"])
    end

    test "propagates registered errors" do
      Sandbox.set_exec_run_responses([
        {~r/.*/, fn _ref, _cmd -> {:error, :enoent} end}
      ])

      assert {:error, :enoent} = Terminal.run("c1", "true", @sandbox)
    end
  end

  describe "run_with_status/3 (sandboxed)" do
    test "returns output + exit_code + running" do
      Sandbox.set_exec_run_with_status_responses([
        {~r/.*/, fn _ref, _cmd -> {:ok, %{output: "ok\n", exit_code: 0, running: false}} end}
      ])

      assert {:ok, %{output: "ok\n", exit_code: 0, running: false}} =
               Terminal.run_with_status("c1", "true", @sandbox)
    end
  end

  describe "command/3 dispatch (no Docker required)" do
    test "binary handle returns :not_found when no session is registered" do
      name = "unregistered-#{System.unique_integer([:positive])}"
      assert {:error, {:not_found, ^name}} = Terminal.command(name, "echo hi")
    end

    test "close/1 of an unregistered name is :ok" do
      name = "unregistered-#{System.unique_integer([:positive])}"
      assert :ok = Terminal.close(name)
    end
  end

  describe "open/2 + command/3 + close/1 against a real daemon" do
    test "name-based open / command / close round-trips through the registered server",
         %{image_tag: image_tag} do
      container_name = "term-name-#{System.unique_integer([:positive])}"

      {:ok, _id} = Docker.create_container(container_name, image_tag, %{})
      on_exit(fn -> Docker.delete_container(container_name, %{force: true}) end)
      {:ok, _} = Docker.start_container(container_name)

      assert {:ok, _state} = Terminal.open(container_name, shell: ["/repl.sh"])

      assert {:ok, pid} = Docker.Terminal.Server.whereis(container_name)
      assert is_pid(pid)
      monitor_ref = Process.monitor(pid)

      assert {:ok, {reply1, ^container_name}} = Terminal.command(container_name, "ping")
      assert String.contains?(reply1, "got: ping")

      assert {:ok, {reply2, ^container_name}} = Terminal.command(container_name, "pong")
      assert String.contains?(reply2, "got: pong")

      assert :ok = Terminal.close(container_name)
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _}, 1_000
    end

    test "open/2 twice for the same name returns {:error, {:already_started, _}}",
         %{image_tag: image_tag} do
      container_name = "term-dup-#{System.unique_integer([:positive])}"

      {:ok, _id} = Docker.create_container(container_name, image_tag, %{})
      on_exit(fn -> Docker.delete_container(container_name, %{force: true}) end)
      {:ok, _} = Docker.start_container(container_name)

      assert {:ok, _state} = Terminal.open(container_name, shell: ["/repl.sh"])

      assert {:error, {:already_started, pid}} =
               Terminal.open(container_name, shell: ["/repl.sh"])

      assert is_pid(pid)

      assert :ok = Terminal.close(container_name)
    end

    test "struct handle is still accepted by command/3 and close/1",
         %{image_tag: image_tag} do
      container_name = "term-struct-#{System.unique_integer([:positive])}"

      {:ok, _id} = Docker.create_container(container_name, image_tag, %{})
      on_exit(fn -> Docker.delete_container(container_name, %{force: true}) end)
      {:ok, _} = Docker.start_container(container_name)

      assert {:ok, state} = Docker.Terminal.Controller.open(container_name, shell: ["/repl.sh"])
      assert {:ok, {reply, state}} = Terminal.command(state, "hi")
      assert String.contains?(reply, "got: hi")
      assert :ok = Terminal.close(state)
    end
  end
end
