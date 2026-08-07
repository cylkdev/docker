ExUnit.start()
Docker.Sandbox.start_link()

# The suite drives a real daemon. Failing here with one clear line beats
# every test failing with a socket error.
case Docker.ping() do
  {:ok, _} ->
    :ok

  {:error, error} ->
    IO.puts(:stderr, """

    The test suite requires a running docker daemon.

      #{error.message}

    Start Docker and run the suite again.
    """)

    System.halt(1)
end

# Pull the test image once rather than letting the first test pay for it.
case Docker.find_image("alpine:3.19") do
  {:ok, _} ->
    :ok

  {:error, _not_present} ->
    {:ok, stream} = Docker.Image.pull_image("alpine:3.19")
    Stream.run(stream)
end
