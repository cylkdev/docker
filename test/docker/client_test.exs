defmodule Docker.ClientTest do
  @moduledoc """
  Exercises the one place in the library that turns a daemon response or a
  transport failure into an `ErrorMessage`, against a real socket rather than
  a canned sandbox response.
  """

  # Not `async: true`: these tests redirect `Docker.Config.socket_path/0`,
  # which is global application config.
  use ExUnit.Case

  alias Docker.Client

  setup do
    original = Application.fetch_env!(:docker, :socket_path)
    on_exit(fn -> Application.put_env(:docker, :socket_path, original) end)
    :ok
  end

  defp start_daemon(responder) do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "docker-client-test-#{System.unique_integer([:positive])}.sock"
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

  defp respond(status, reason, body, content_type \\ "application/json") do
    fn _request ->
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "Content-Type: #{content_type}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    end
  end

  describe "request/4 against a daemon that answers" do
    test "a 2xx passes through as {:ok, response}" do
      start_daemon(respond(200, "OK", ~s({"Id":"abc"})))

      assert {:ok, %{status: 200, body: %{"Id" => "abc"}}} =
               Client.request(:get, "/containers/abc/json")
    end

    test "a 404 becomes :not_found and lifts the daemon's message" do
      start_daemon(respond(404, "Not Found", ~s({"message":"No such container: ghost"})))

      assert {:error, %ErrorMessage{} = error} = Client.request(:get, "/containers/ghost/json")

      assert error.code === :not_found
      assert error.message === "No such container: ghost"

      assert %{
               status: 404,
               method: :get,
               path: path,
               body: %{"message" => "No such container: ghost"}
             } = error.details

      assert String.ends_with?(path, "/containers/ghost/json")
    end

    test "a 409 becomes :conflict" do
      start_daemon(respond(409, "Conflict", ~s({"message":"container is running"})))

      assert {:error, %ErrorMessage{code: :conflict, message: "container is running"}} =
               Client.request(:delete, "/containers/busy")
    end

    test "a 304 becomes :not_modified" do
      start_daemon(respond(304, "Not Modified", ""))

      assert {:error, %ErrorMessage{code: :not_modified, details: %{status: 304}}} =
               Client.request(:post, "/containers/running/start")
    end

    test "a 500 becomes :internal_server_error" do
      start_daemon(respond(500, "Internal Server Error", ~s({"message":"boom"})))

      assert {:error, %ErrorMessage{code: :internal_server_error, message: "boom"}} =
               Client.request(:get, "/info")
    end

    test "a plain-text error body becomes the message" do
      start_daemon(respond(400, "Bad Request", "page not found\n", "text/plain"))

      assert {:error, %ErrorMessage{code: :bad_request, message: "page not found"}} =
               Client.request(:get, "/bogus")
    end

    test "an empty error body falls back to a generated message" do
      start_daemon(respond(403, "Forbidden", ""))

      assert {:error, %ErrorMessage{code: :forbidden, message: message}} =
               Client.request(:get, "/containers/json")

      assert message === "The Docker daemon responded with HTTP 403"
    end

    test "a status outside ErrorMessage's table falls back rather than raising" do
      start_daemon(respond(599, "Whatever", "odd", "text/plain"))

      assert {:error, %ErrorMessage{code: :internal_server_error, details: %{status: 599}}} =
               Client.request(:get, "/info")
    end

    test "a body that will not decode becomes :bad_gateway, not :service_unavailable" do
      start_daemon(respond(200, "OK", "not json at all"))

      assert {:error, %ErrorMessage{code: :bad_gateway, message: message}} =
               Client.request(:get, "/info")

      assert message =~ "could not read"
    end
  end

  describe "request/4 against a daemon that is not there" do
    test "a missing socket becomes :service_unavailable" do
      missing =
        Path.join(System.tmp_dir!(), "docker-absent-#{System.unique_integer([:positive])}")

      Application.put_env(:docker, :socket_path, missing)

      assert {:error, %ErrorMessage{code: :service_unavailable} = error} =
               Client.request(:get, "/_ping")

      assert error.message =~ "Could not reach the Docker daemon"
      assert %{socket_path: ^missing, method: :get, reason: _} = error.details
    end
  end

  describe "stream/4" do
    # `stream/4` drains the error body as raw bytes, so this also pins that it
    # reaches the same message `request/4` would give for the same response.
    test "a non-2xx status becomes an ErrorMessage with the body drained" do
      start_daemon(respond(404, "Not Found", ~s({"message":"no such image"})))

      assert {:error, %ErrorMessage{code: :not_found, message: "no such image"}} =
               Client.stream(:post, "/images/create?fromImage=ghost")
    end

    test "a missing socket becomes :service_unavailable" do
      missing =
        Path.join(System.tmp_dir!(), "docker-absent-#{System.unique_integer([:positive])}")

      Application.put_env(:docker, :socket_path, missing)

      assert {:error, %ErrorMessage{code: :service_unavailable}} =
               Client.stream(:post, "/images/create?fromImage=alpine")
    end
  end
end
