defmodule Docker.Engine.ExecTest do
  @moduledoc "Exec against a real daemon."

  use DaemonCase

  describe "resize_path/3" do
    test "builds the exec resize path with h and w query params" do
      assert Docker.Exec.resize_path("abc123", 40, 120) === "/exec/abc123/resize?h=40&w=120"
    end
  end

  describe "exec_run/3" do
    test "runs an argv list and returns its output" do
      id = start_container!(["sleep", "30"])

      assert {:ok, output} = Docker.exec_run(id, ["/bin/echo", "hello"])
      assert output =~ "hello"
    end

    test "runs a string command under /bin/sh -c" do
      id = start_container!(["sleep", "30"])

      assert {:ok, output} = Docker.exec_run(id, "echo one && echo two")
      assert output =~ "one"
      assert output =~ "two"
    end
  end

  describe "exec_run_with_status/3" do
    test "reports a zero exit code and the output" do
      id = start_container!(["sleep", "30"])

      assert {:ok, %{output: output, exit_code: 0, running: false}} =
               Docker.exec_run_with_status(id, "echo done")

      assert output =~ "done"
    end

    test "reports a non-zero exit code" do
      id = start_container!(["sleep", "30"])

      assert {:ok, %{exit_code: 7, running: false}} =
               Docker.exec_run_with_status(id, "exit 7")
    end
  end

  describe "exec_create/3, exec_start/2 and exec_inspect/2" do
    test "the three steps compose into one run" do
      id = start_container!(["sleep", "30"])

      assert {:ok, exec_id} = Docker.exec_create(id, ["/bin/echo", "composed"])
      assert {:ok, output} = Docker.exec_start(exec_id)
      assert output =~ "composed"

      assert {:ok, %{"ExitCode" => 0, "Running" => false}} = Docker.exec_inspect(exec_id)
    end

    test "exec_inspect on an unknown id is :not_found" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               Docker.exec_inspect("0123456789abcdef0123456789abcdef0123456789abcdef")
    end
  end
end
