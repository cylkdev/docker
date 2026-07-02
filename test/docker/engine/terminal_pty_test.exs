defmodule Docker.Terminal.PtyTest do
  use ExUnit.Case, async: true
  alias Docker.Terminal.{Handle, Pty}

  describe "handle_stream_message/1" do
    test "maps a data message to {:write, bytes}" do
      assert {:write, "abc"} = Pty.handle_stream_message({:docker_stream, self(), :data, "abc"})
    end

    test "maps a closed message to :halt" do
      assert :halt = Pty.handle_stream_message({:docker_stream, self(), :closed})
    end
  end

  describe "forward_keystrokes/2" do
    test "sends bytes to the handle's stream transport" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, tcp_port} = :inet.port(listen)
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", tcp_port, [:binary, active: false, packet: :raw])
      {:ok, server} = :gen_tcp.accept(listen)

      handle = %Handle{stream: Docker.Streaming.Session.from_upgrade(client, "", true)}
      assert :ok = Pty.forward_keystrokes("l", handle)
      assert {:ok, "l"} = :gen_tcp.recv(server, 0, 200)
      Docker.Streaming.Session.close(handle.stream)
    end
  end

  describe "on_winch/1" do
    test "tolerates errors (no exec id) and returns :ok" do
      assert :ok = Pty.on_winch(%Handle{exec_id: nil})
    end
  end
end
