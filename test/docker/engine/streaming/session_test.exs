defmodule Docker.Streaming.SessionTest do
  use ExUnit.Case

  alias Docker.Streaming.Session

  @dockerfile "examples/busybox-example/Dockerfile"
  @context_path "examples/busybox-example"

  setup_all do
    image_tag = unique_image_tag("docker-test:tiny")

    # build_image/5 returns a stream; the build runs only as it's consumed.
    {:ok, build_events} = Docker.build_image(@context_path, @dockerfile, image_tag)
    Enum.each(build_events, fn _ev -> :ok end)

    on_exit(fn -> Docker.delete_image(image_tag, %{}) end)

    {:ok, %{image_tag: image_tag}}
  end

  describe "recv/3 demux state (unit, no daemon)" do
    test "preserves a partial frame in frame_buffer across reads" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

      {:ok, server} = :gen_tcp.accept(listen)

      session = Session.from_upgrade(client, "", false)

      # Send only a header and partial payload
      :gen_tcp.send(server, <<1, 0, 0, 0, 0, 0, 0, 5, "hel">>)
      {:ok, "", session} = Session.recv(session, {:idle_timeout, 50})
      assert session.frame_buffer === <<1, 0, 0, 0, 0, 0, 0, 5, "hel">>

      # Send the rest -- completes the frame
      :gen_tcp.send(server, "lo")
      {:ok, "hello", session} = Session.recv(session, {:idle_timeout, 50})
      assert session.frame_buffer === ""

      Session.close(session)
    end

    test "from_upgrade/3 ingests leftover bytes immediately" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

      {:ok, _server} = :gen_tcp.accept(listen)

      leftover = <<1, 0, 0, 0, 0, 0, 0, 5, "hello">>
      session = Session.from_upgrade(client, leftover, false)

      assert session.buffer === "hello"
      assert session.frame_buffer === ""

      Session.close(session)
    end

    test "tty: true bypasses framing entirely" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

      {:ok, _server} = :gen_tcp.accept(listen)

      session = Session.from_upgrade(client, "raw bytes no framing", true)

      assert session.buffer === "raw bytes no framing"
      assert session.frame_buffer === ""
      assert session.stderr_buffer === ""

      Session.close(session)
    end

    test "send/2 on a closed session returns {:error, :closed}" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

      {:ok, _server} = :gen_tcp.accept(listen)

      session = Session.from_upgrade(client, "", false)
      Session.close(session)

      closed_session = %{session | closed: true}
      assert {:error, :closed} = Session.send(closed_session, "hello\n")
    end

    test "close/1 is idempotent" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

      {:ok, _server} = :gen_tcp.accept(listen)

      session = Session.from_upgrade(client, "", false)
      assert Session.close(session)
      assert Session.close(%{session | closed: true})
    end
  end

  describe "attach/2" do
    test "drives the entrypoint via send/recv with idle_timeout", %{image_tag: image_tag} do
      container_id = create_repl_container("ci-attach-repl", image_tag)

      {:ok, session} = Docker.attach(container_id)

      {:ok, _initial, session} =
        Docker.Streaming.Session.recv(session, {:idle_timeout, 200})

      Docker.Streaming.Session.send(session, "hello\n")
      {:ok, first, session} = Docker.Streaming.Session.recv(session, {:idle_timeout, 500})
      assert String.contains?(first, "got: hello")

      Docker.Streaming.Session.send(session, "world\n")
      {:ok, second, session} = Docker.Streaming.Session.recv(session, {:idle_timeout, 500})
      assert String.contains?(second, "got: world")

      Docker.Streaming.Session.close(session)
    end

    test "recv with delimiter returns through the delimiter only", %{image_tag: image_tag} do
      container_id = create_repl_container("ci-attach-delim", image_tag)

      {:ok, session} = Docker.attach(container_id)
      Docker.Streaming.Session.send(session, "alpha\n")

      {:ok, output, session} =
        Docker.Streaming.Session.recv(session, {:until, "got: alpha\n"}, timeout: 5_000)

      assert String.ends_with?(output, "got: alpha\n")
      assert session.buffer === ""

      Docker.Streaming.Session.close(session)
    end

    test "tty container attach uses raw stream (no multiplex framing)", %{image_tag: image_tag} do
      container_name = unique_container_name("ci-attach-tty")

      {:ok, container_id} =
        Docker.create_container(
          container_name,
          image_tag,
          %{},
          auto_remove: false,
          interactive_shell: true
        )

      on_exit(fn -> Docker.delete_container(container_id, %{force: true}) end)
      {:ok, _} = Docker.start_container(container_id)
      wait_for_container_running(container_id)
      assert wait_for_container_ready(container_id)

      {:ok, session} = Docker.attach(container_id)
      assert session.tty === true

      {:ok, _initial, session} =
        Docker.Streaming.Session.recv(session, {:idle_timeout, 200})

      Docker.Streaming.Session.send(session, "echo from-tty\n")

      {:ok, output, session} = Docker.Streaming.Session.recv(session, {:idle_timeout, 500})
      assert String.contains?(output, "from-tty")

      Docker.Streaming.Session.close(session)
    end
  end

  describe "exec_session/3" do
    test "writes to exec stdin and reads stdout", %{image_tag: image_tag} do
      container_name = unique_container_name("ci-exec-session")
      container_id = create_running_container(container_name, image_tag)

      {:ok, session} = Docker.exec_session(container_id, ["cat"])
      Docker.Streaming.Session.send(session, "ping\n")

      {:ok, output, session} = Docker.Streaming.Session.recv(session, {:idle_timeout, 500})
      assert String.contains?(output, "ping")

      Docker.Streaming.Session.close(session)
    end

    test "split: true returns stdout and stderr separately", %{image_tag: image_tag} do
      container_name = unique_container_name("ci-exec-split")
      container_id = create_running_container(container_name, image_tag)

      {:ok, session} =
        Docker.exec_session(container_id, ["sh", "-c", "echo out; echo err 1>&2"])

      {:ok, {stdout, stderr}, _session} =
        Docker.Streaming.Session.recv(session, {:idle_timeout, 500}, split: true)

      assert stdout === "out\n"
      assert stderr === "err\n"
    end

    test "recv :until returns :closed_before_delimiter when process exits", %{
      image_tag: image_tag
    } do
      container_name = unique_container_name("ci-exec-closed")
      container_id = create_running_container(container_name, image_tag)

      {:ok, session} = Docker.exec_session(container_id, ["sh", "-c", "echo done"])

      assert {:error, :closed_before_delimiter, _session} =
               Docker.Streaming.Session.recv(session, {:until, "FOREVER"}, timeout: 2_000)
    end
  end

  describe "send_message/4" do
    test "open, send, recv, close in one call", %{image_tag: image_tag} do
      container_id = create_repl_container("ci-send-message", image_tag)

      assert {:ok, output} =
               Docker.send_message(container_id, "yo\n", {:idle_timeout, 500})

      assert String.contains?(output, "got: yo")
    end
  end

  defp create_repl_container(prefix, image_tag) do
    container_name = unique_container_name(prefix)

    {:ok, container_id} =
      Docker.create_container(
        container_name,
        image_tag,
        %{},
        auto_remove: false,
        open_stdin: true,
        cmd: ["repl"]
      )

    on_exit(fn -> Docker.delete_container(container_id, %{force: true}) end)

    {:ok, _} = Docker.start_container(container_id)
    wait_for_container_running(container_id)
    assert wait_for_container_ready(container_id)
    container_id
  end

  defp unique_container_name(prefix), do: unique_name(prefix)

  defp unique_image_tag(prefix), do: unique_name(prefix)

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp create_running_container(container_name, image_tag) do
    {:ok, container_id} =
      Docker.create_container(
        container_name,
        image_tag,
        %{},
        auto_remove: false,
        interactive_shell: true
      )

    on_exit(fn -> Docker.delete_container(container_id, %{force: true}) end)

    assert {:ok, _} = Docker.start_container(container_id)
    wait_for_container_running(container_id)
    assert wait_for_container_ready(container_id)
    container_id
  end

  defp wait_for_container_running(container_id, attempts_left \\ 40)

  defp wait_for_container_running(_container_id, 0), do: false

  defp wait_for_container_running(container_id, attempts_left) do
    if Docker.container_running?(container_id) do
      true
    else
      :timer.sleep(100)
      wait_for_container_running(container_id, attempts_left - 1)
    end
  end

  defp wait_for_container_ready(container_id, attempts_left \\ 200)

  defp wait_for_container_ready(_container_id, 0), do: false

  defp wait_for_container_ready(container_id, attempts_left) do
    case Docker.container_logs(container_id) do
      {:ok, logs} when is_binary(logs) ->
        String.contains?(logs, "READY")

      _ ->
        :timer.sleep(100)
        wait_for_container_ready(container_id, attempts_left - 1)
    end
  end
end
