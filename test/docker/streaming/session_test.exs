defmodule Docker.Streaming.SessionTest do
  use ExUnit.Case, async: true

  alias Docker.Streaming.Session

  # `transport_recv/2` reads `{:docker_stream, socket, ...}` out of the calling
  # process's mailbox, so a session whose socket is `self()` can be driven by
  # sending to ourselves — no daemon and no connection process involved.
  defp fake_session(opts \\ []) do
    Session.from_connection(self(), Keyword.get(opts, :tty, true))
  end

  defp feed(data) do
    send(self(), {:docker_stream, self(), :data, data})
  end

  describe "recv/3 with {:until, delimiter}" do
    test "returns the buffered output up to and including the delimiter" do
      feed("hello END rest")

      assert {:ok, "hello END", session} =
               Session.recv(fake_session(), {:until, "END"}, timeout: 200)

      assert session.buffer === " rest"
    end

    test "a timeout returns a :request_timeout error carrying the session" do
      feed("partial output")

      assert {:error, %ErrorMessage{code: :request_timeout, details: details}} =
               Session.recv(fake_session(), {:until, "NEVER"}, timeout: 50)

      assert %{delimiter: "NEVER", session: %Session{} = session} = details

      # The load-bearing part: bytes that arrived before the timeout are still
      # in the returned session. Callers that hold state across reads (see
      # `Docker.Terminal`) would silently drop output if this regressed.
      assert session.buffer === "partial output"
    end

    test "a closed transport returns a :gone error carrying the session" do
      feed("partial output")
      send(self(), {:docker_stream, self(), :closed})

      assert {:error, %ErrorMessage{code: :gone, details: details}} =
               Session.recv(fake_session(), {:until, "NEVER"}, timeout: 500)

      assert %{delimiter: "NEVER", session: %Session{} = session} = details
      assert session.buffer === "partial output"
      assert session.closed
    end
  end

  describe "recv/3 with {:idle_timeout, ms}" do
    test "returns everything received before the stream went idle" do
      feed("one ")
      feed("two")

      assert {:ok, "one two", session} = Session.recv(fake_session(), {:idle_timeout, 50})
      assert session.buffer === ""
    end
  end

  describe "a closed session" do
    test "recv/3 returns a :gone error carrying the session" do
      session = %{fake_session() | closed: true}

      assert {:error, %ErrorMessage{code: :gone, details: %{session: %Session{closed: true}}}} =
               Session.recv(session, {:idle_timeout, 10})
    end

    test "send/2 returns a :gone error" do
      session = %{fake_session() | closed: true}

      assert {:error, %ErrorMessage{code: :gone}} = Session.send(session, "ls\n")
    end
  end
end
