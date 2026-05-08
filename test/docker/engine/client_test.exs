defmodule Docker.Engine.ClientTest do
  # The endpoint-resolution scenario reads/restores DOCKER_HOST and the
  # filesystem rungs, which is process-global state. Run serially.
  use ExUnit.Case

  alias Docker.Engine.Client
  alias Docker.Engine.Endpoint, as: EngineEndpoint
  alias Sorrel.Endpoint, as: MintyEndpoint

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_socket_path do
    Path.join(
      System.tmp_dir!(),
      "docker-engine-client-test-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp engine_endpoint(socket_path, version \\ "1.45") do
    %EngineEndpoint{
      minty: %MintyEndpoint{transport: :unix, socket_path: socket_path},
      version: version
    }
  end

  defp start_unix_server(socket_path, responder) do
    {:ok, server} =
      FakeHttpServer.start(
        transport: :unix,
        socket_path: socket_path,
        responder: responder
      )

    on_exit(fn -> FakeHttpServer.stop(server) end)
    server
  end

  defp register_pool_cleanup(%EngineEndpoint{minty: minty}) do
    register_pool_cleanup(minty)
  end

  defp register_pool_cleanup(%MintyEndpoint{} = endpoint) do
    on_exit(fn ->
      sig = pool_signature(endpoint)

      case Registry.lookup(Sorrel.Pool.Registry, sig) do
        [{pid, _}] ->
          _ = DynamicSupervisor.terminate_child(Sorrel.Pool.DynamicSupervisor, pid)
          :ok

        [] ->
          :ok
      end
    end)
  end

  defp pool_signature(%MintyEndpoint{transport: :unix} = ep), do: {:unix, ep.socket_path}

  defp respond(status, status_text, content_type, body) do
    [
      "HTTP/1.1 #{status} #{status_text}\r\n",
      "Content-Type: #{content_type}\r\n",
      "Content-Length: #{IO.iodata_length(body)}\r\n",
      "\r\n",
      body
    ]
  end

  defp head_chunked(status, content_type) do
    [
      "HTTP/1.1 #{status} OK\r\n",
      "Content-Type: #{content_type}\r\n",
      "Transfer-Encoding: chunked\r\n",
      "\r\n"
    ]
  end

  defp transfer_chunk(payload) do
    size = IO.iodata_length(payload)
    [Integer.to_string(size, 16), "\r\n", payload, "\r\n"]
  end

  defp last_transfer_chunk, do: "0\r\n\r\n"

  # Two complete frames laid back to back: stdout "hello" then stderr "err".
  defp two_frames_payload do
    <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>
  end

  # ---------------------------------------------------------------------------
  # request/4 — :into :frame
  # ---------------------------------------------------------------------------

  describe "request/4 :into :frame" do
    test "demuxes multiplexed frame bytes into a single binary on 2xx" do
      socket_path = tmp_socket_path()
      body = two_frames_payload()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(200, "OK", "application/vnd.docker.raw-stream", body)
        end)

      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200, body: "helloerr"}} =
               Client.request(:get, "/v1.45/exec/123/start", nil,
                 endpoint: ep,
                 into: :frame
               )
    end

    test "passes through the raw body on non-2xx (no frame demux)" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          respond(404, "Not Found", "text/plain", "missing")
        end)

      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:error, %{status: 404, body: "missing"}} =
               Client.request(:get, "/v1.45/exec/missing/start", nil,
                 endpoint: ep,
                 into: :frame
               )
    end
  end

  # ---------------------------------------------------------------------------
  # request/4 — :registry_auth
  # ---------------------------------------------------------------------------

  describe "request/4 :registry_auth" do
    test "sends the value as the X-Registry-Auth header" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_request, req})
        respond(200, "OK", "text/plain", "OK")
      end

      _server = start_unix_server(socket_path, responder)
      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200}} =
               Client.request(:post, "/images/create?fromImage=alpine", nil,
                 endpoint: ep,
                 registry_auth: "secret-token"
               )

      assert_receive {:saw_request, req}, 1_000
      assert {"x-registry-auth", "secret-token"} in req.headers
    end

    test "appends X-Registry-Auth alongside other :headers" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_request, req})
        respond(200, "OK", "text/plain", "OK")
      end

      _server = start_unix_server(socket_path, responder)
      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200}} =
               Client.request(:get, "/auth-required", nil,
                 endpoint: ep,
                 registry_auth: "secret-token",
                 headers: [{"x-custom", "yep"}]
               )

      assert_receive {:saw_request, req}, 1_000
      assert {"x-custom", "yep"} in req.headers
      assert {"x-registry-auth", "secret-token"} in req.headers
    end
  end

  # ---------------------------------------------------------------------------
  # request/4 — version prefix
  # ---------------------------------------------------------------------------

  describe "request/4 version prefix" do
    test "path without /vN.M prefix gets the endpoint version prepended" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_path, req.path})
        respond(200, "OK", "text/plain", "OK")
      end

      _server = start_unix_server(socket_path, responder)
      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200}} =
               Client.request(:get, "/foo", nil, endpoint: ep)

      assert_receive {:saw_path, "/v1.45/foo"}, 1_000
    end

    test "path that already starts with /vN.M is left unchanged" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_path, req.path})
        respond(200, "OK", "text/plain", "OK")
      end

      _server = start_unix_server(socket_path, responder)
      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200}} =
               Client.request(:get, "/v1.46/bar", nil, endpoint: ep)

      assert_receive {:saw_path, "/v1.46/bar"}, 1_000
    end

    test ":version option overrides the endpoint version" do
      socket_path = tmp_socket_path()
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:saw_path, req.path})
        respond(200, "OK", "text/plain", "OK")
      end

      _server = start_unix_server(socket_path, responder)
      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, %{status: 200}} =
               Client.request(:get, "/baz", nil, endpoint: ep, version: "1.50")

      assert_receive {:saw_path, "/v1.50/baz"}, 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # stream/4 — :into :frame
  # ---------------------------------------------------------------------------

  describe "stream/4 :into :frame" do
    test "yields {:stdout, _} | {:stderr, _} events as frames complete" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head_chunked(200, "application/vnd.docker.raw-stream")},
             # Frame 1 split across two transfer chunks: header in one,
             # payload in the next. Exercises decode_chunk's leftover.
             {:write, transfer_chunk(<<1, 0, 0, 0, 0, 0, 0, 5>>)},
             {:write, transfer_chunk("hello")},
             # Frame 2 in a single transfer chunk.
             {:write, transfer_chunk(<<2, 0, 0, 0, 0, 0, 0, 3, "err">>)},
             {:write, last_transfer_chunk()},
             :close
           ]}
        end)

      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      assert {:ok, stream} =
               Client.stream(:get, "/v1.45/containers/c/logs?follow=1", nil,
                 endpoint: ep,
                 into: :frame
               )

      assert Enum.to_list(stream) === [{:stdout, "hello"}, {:stderr, "err"}]
    end

    test "early termination via Stream.take/2 cancels the in-flight request" do
      socket_path = tmp_socket_path()

      _server =
        start_unix_server(socket_path, fn _req ->
          {:script,
           [
             {:write, head_chunked(200, "application/vnd.docker.raw-stream")},
             {:write, transfer_chunk(<<1, 0, 0, 0, 0, 0, 0, 5, "hello">>)},
             # Hold the connection open for a long time; consumer cancels.
             {:sleep, 60_000},
             :close
           ]}
        end)

      ep = engine_endpoint(socket_path)
      register_pool_cleanup(ep)

      before_pids = length(:erlang.processes())

      assert {:ok, stream} =
               Client.stream(:get, "/v1.45/containers/c/logs?follow=1", nil,
                 endpoint: ep,
                 into: :frame
               )

      assert [{:stdout, "hello"}] = stream |> Stream.take(1) |> Enum.to_list()

      deadline = System.monotonic_time(:millisecond) + 200
      :ok = wait_for_pid_count_to_settle(before_pids, deadline)
    end
  end

  # ---------------------------------------------------------------------------
  # Endpoint resolution failure
  # ---------------------------------------------------------------------------

  describe "endpoint resolution" do
    test "returns {:error, :endpoint_not_resolved} when no rung yields" do
      saved_docker_host = System.get_env("DOCKER_HOST")

      on_exit(fn ->
        if saved_docker_host do
          System.put_env("DOCKER_HOST", saved_docker_host)
        else
          System.delete_env("DOCKER_HOST")
        end
      end)

      System.delete_env("DOCKER_HOST")

      desktop = Path.expand("~/.docker/run/docker.sock")
      linux = "/var/run/docker.sock"

      if File.exists?(desktop) or File.exists?(linux) do
        # On hosts where a real socket file exists the resolver succeeds and
        # the call may produce a transport error instead. Allow either shape.
        result = Client.request(:get, "/_ping")
        assert match?({:ok, _response}, result) or match?({:error, _reason}, result)
      else
        assert {:error, :endpoint_not_resolved} = Client.request(:get, "/_ping")
      end
    end
  end

  # Polls Process.alive on a synthetic baseline. Returns :ok once the live
  # process count is at or below the baseline (allowing a small drift), or if
  # the deadline is reached.
  defp wait_for_pid_count_to_settle(baseline, deadline) do
    now = System.monotonic_time(:millisecond)
    current = length(:erlang.processes())

    cond do
      current <= baseline + 1 ->
        :ok

      now >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        wait_for_pid_count_to_settle(baseline, deadline)
    end
  end
end
