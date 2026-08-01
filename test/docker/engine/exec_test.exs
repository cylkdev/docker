defmodule Docker.Engine.ExecTest do
  use ExUnit.Case

  alias Docker.Exec
  alias Docker.Sandbox

  @sandbox [sandbox: [enabled: true]]

  describe "resize_path/3" do
    test "builds the exec resize path with h and w query params" do
      assert Docker.Exec.resize_path("abc123", 40, 120) == "/exec/abc123/resize?h=40&w=120"
    end
  end

  describe "exec_run/3 (sandboxed)" do
    test "runs a string command, wrapping it under /bin/sh -c" do
      Sandbox.set_exec_run_responses([
        {~r/.*/, fn _ref, cmd -> {:ok, "wrapped:#{inspect(cmd)}"} end}
      ])

      assert {:ok, "wrapped:" <> rest} = Exec.exec_run("c1", "echo hello", @sandbox)
      assert rest === inspect(["/bin/sh", "-c", "echo hello"])
    end

    test "passes an argv list through verbatim" do
      Sandbox.set_exec_run_responses([
        {~r/.*/, fn _ref, cmd -> {:ok, "raw:#{inspect(cmd)}"} end}
      ])

      assert {:ok, "raw:" <> rest} = Exec.exec_run("c1", ["ls", "/etc"], @sandbox)
      assert rest === inspect(["ls", "/etc"])
    end

    test "propagates registered errors" do
      Sandbox.set_exec_run_responses([
        {~r/.*/, fn _ref, _cmd -> {:error, ErrorMessage.not_found("no such container")} end}
      ])

      assert {:error, %ErrorMessage{code: :not_found}} = Exec.exec_run("c1", "true", @sandbox)
    end
  end

  describe "exec_run_with_status/3 (sandboxed)" do
    test "returns output + exit_code + running" do
      Sandbox.set_exec_run_with_status_responses([
        {~r/.*/, fn _ref, _cmd -> {:ok, %{output: "ok\n", exit_code: 0, running: false}} end}
      ])

      assert {:ok, %{output: "ok\n", exit_code: 0, running: false}} =
               Exec.exec_run_with_status("c1", "true", @sandbox)
    end

    test "wraps a string command under /bin/sh -c" do
      Sandbox.set_exec_run_with_status_responses([
        {~r/.*/, fn _ref, cmd -> {:ok, %{output: inspect(cmd), exit_code: 0, running: false}} end}
      ])

      assert {:ok, %{output: output}} = Exec.exec_run_with_status("c1", "true", @sandbox)
      assert output === inspect(["/bin/sh", "-c", "true"])
    end
  end
end
