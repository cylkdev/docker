defmodule Docker.ContainersTest do
  @moduledoc """
  Exercises the archive and wait endpoints against a real socket, covering the
  request-building and response-decoding that sandbox mode bypasses.
  """

  # Not `async: true`: these tests redirect `Docker.Config.socket_path/0`,
  # which is global application config.
  use ExUnit.Case

  alias Docker.Containers

  setup do
    original = Application.fetch_env!(:docker, :socket_path)
    on_exit(fn -> Application.put_env(:docker, :socket_path, original) end)
    :ok
  end

  defp start_daemon(responder) do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "docker-containers-test-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, server} =
      FakeHttpServer.start(transport: :unix, socket_path: socket_path, responder: responder)

    Application.put_env(:docker, :socket_path, socket_path)

    on_exit(fn ->
      FakeHttpServer.stop(server)
      File.rm(socket_path)
    end)

    :ok
  end

  # Captures the request line so a test can assert on the URL that was built.
  defp echoing_daemon(response_fun) do
    test_pid = self()

    fn request ->
      send(test_pid, {:request, request.method, request.path})
      response_fun.(request)
    end
  end

  defp tar_response(body) do
    fn _request ->
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: application/x-tar\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    end
  end

  defp stat_response(header_value) do
    fn _request ->
      "HTTP/1.1 200 OK\r\n" <>
        "X-Docker-Container-Path-Stat: #{header_value}\r\n" <>
        "Content-Length: 0\r\n\r\n"
    end
  end

  defp wait_response(body) do
    fn _request ->
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    end
  end

  describe "get_archive/3" do
    test "returns the tar body undecoded and sends the path as a query param" do
      start_daemon(echoing_daemon(tar_response("tar-bytes")))

      assert {:ok, "tar-bytes"} = Containers.get_archive("c1", "/app/build")

      assert_receive {:request, "GET", path}
      assert path =~ "/containers/c1/archive"
      assert path =~ "path=%2Fapp%2Fbuild"
    end

    test "a 404 becomes :not_found" do
      start_daemon(fn _request ->
        body = ~s({"message":"Could not find the file /nope in container c1"})

        "HTTP/1.1 404 Not Found\r\n" <>
          "Content-Type: application/json\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
      end)

      assert {:error, %ErrorMessage{code: :not_found} = error} =
               Containers.get_archive("c1", "/nope")

      assert error.message === "Could not find the file /nope in container c1"
    end
  end

  describe "stat_archive/3" do
    test "decodes the base64 JSON stat header" do
      stat = %{"name" => "build", "size" => 4096, "mode" => 493, "linkTarget" => ""}
      start_daemon(echoing_daemon(stat_response(Base.encode64(JSON.encode!(stat)))))

      assert {:ok, ^stat} = Containers.stat_archive("c1", "/app/build")
      assert_receive {:request, "HEAD", _path}
    end

    test "a missing stat header is :internal_server_error" do
      start_daemon(fn _request -> "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" end)

      assert {:error, %ErrorMessage{code: :internal_server_error} = error} =
               Containers.stat_archive("c1", "/app/build")

      assert error.details.reason === :missing_header
    end

    test "an undecodable base64 header is :internal_server_error" do
      start_daemon(stat_response("not!valid!base64"))

      assert {:error, %ErrorMessage{code: :internal_server_error} = error} =
               Containers.stat_archive("c1", "/app/build")

      assert error.details.reason === :invalid_base64
    end

    test "a header that is valid base64 but not JSON is :internal_server_error" do
      start_daemon(stat_response(Base.encode64("this is not json")))

      assert {:error, %ErrorMessage{code: :internal_server_error} = error} =
               Containers.stat_archive("c1", "/app/build")

      assert error.details.reason === :invalid_json
    end

    test "a header encoding a JSON non-object is :internal_server_error" do
      start_daemon(stat_response(Base.encode64(~s(["not","an","object"]))))

      assert {:error, %ErrorMessage{code: :internal_server_error} = error} =
               Containers.stat_archive("c1", "/app/build")

      assert error.details.reason === :not_an_object
    end
  end

  describe "wait_container/3" do
    test "returns the decoded exit status" do
      start_daemon(echoing_daemon(wait_response(~s({"StatusCode":0,"Error":null}))))

      assert {:ok, %{"StatusCode" => 0, "Error" => nil}} = Containers.wait_container("c1")

      assert_receive {:request, "POST", path}
      assert path =~ "/containers/c1/wait"
    end

    test "a non-zero exit code is still {:ok, _}" do
      start_daemon(wait_response(~s({"StatusCode":137,"Error":null})))

      assert {:ok, %{"StatusCode" => 137}} = Containers.wait_container("c1")
    end

    test "puts the condition in the query string" do
      start_daemon(echoing_daemon(wait_response(~s({"StatusCode":0}))))

      assert {:ok, _} = Containers.wait_container("c1", %{condition: "next-exit"})

      assert_receive {:request, "POST", path}
      assert path =~ "condition=next-exit"
    end

    test "an explicit :receive_timeout wins over the infinite default" do
      # Holds the connection open without answering, the way the real daemon
      # does while a container is still running.
      start_daemon(fn _request -> {:script, [{:sleep, 5_000}, :close]} end)

      assert {:error, %ErrorMessage{code: :gateway_timeout}} =
               Containers.wait_container("c1", %{}, receive_timeout: 100)
    end
  end
end
