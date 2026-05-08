defmodule Docker.Engine.EndpointTest do
  use ExUnit.Case

  alias Docker.Engine.Endpoint, as: EngineEndpoint
  alias Sorrel.Endpoint, as: MintyEndpoint

  # ---------------------------------------------------------------------------
  # Per-test isolation of System env vars.
  #
  # Why: rung 4 of from_options/1 reads DOCKER_HOST, DOCKER_TLS_VERIFY,
  # DOCKER_CERT_PATH. Tests in this file mutate those values; we must
  # restore them so they do not leak across tests.
  # ---------------------------------------------------------------------------

  @env_keys ["DOCKER_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"]

  setup do
    saved_env = Map.new(@env_keys, fn k -> {k, System.get_env(k)} end)

    # Clear env vars so a stray DOCKER_HOST in the surrounding shell does
    # not contaminate scenarios that assume "no env set".
    for k <- @env_keys, do: System.delete_env(k)

    on_exit(fn ->
      for {k, v} <- saved_env do
        if v do
          System.put_env(k, v)
        else
          System.delete_env(k)
        end
      end
    end)

    :ok
  end

  # ===========================================================================
  # from_options/1 — precedence ladder
  # ===========================================================================

  describe "from_options/1 precedence ladder" do
    test "rung 1: options[:endpoint] is used as-is" do
      ep = %EngineEndpoint{
        minty: %MintyEndpoint{transport: :unix, socket_path: "/x"},
        version: "1.45"
      }

      assert {:ok, ^ep} = EngineEndpoint.from_options(endpoint: ep)
    end

    test "rung 2: options[:host] is parsed" do
      assert {:ok, ep} = EngineEndpoint.from_options(host: "tcp://10.0.0.1:2375")
      assert ep.version === "1.45"
      assert ep.minty.transport === :tcp
      assert ep.minty.scheme === :http
      assert ep.minty.host === "10.0.0.1"
      assert ep.minty.port === 2375
    end

    test "rung 3: options[:socket] produces a unix endpoint" do
      assert {:ok, ep} = EngineEndpoint.from_options(socket: "/tmp/d.sock")
      assert ep.version === "1.45"
      assert ep.minty.transport === :unix
      assert ep.minty.socket_path === "/tmp/d.sock"
    end

    test "rung 4: DOCKER_HOST environment variable" do
      System.put_env("DOCKER_HOST", "tcp://h:2375")
      assert {:ok, ep} = EngineEndpoint.from_options([])
      assert ep.version === "1.45"
      assert ep.minty.transport === :tcp
      assert ep.minty.scheme === :http
      assert ep.minty.host === "h"
      assert ep.minty.port === 2375
    end

    test "rung 5: filesystem default — Docker Desktop socket" do
      tmp_home = mktemp_dir!()
      desktop_dir = Path.join([tmp_home, ".docker", "run"])
      File.mkdir_p!(desktop_dir)
      desktop_sock = Path.join(desktop_dir, "docker.sock")
      File.touch!(desktop_sock)

      saved_home = System.get_env("HOME")
      System.put_env("HOME", tmp_home)

      try do
        assert {:ok, ep} = EngineEndpoint.from_options([])
        assert ep.minty.transport === :unix
        assert ep.minty.socket_path === Path.expand("~/.docker/run/docker.sock")
      after
        if saved_home do
          System.put_env("HOME", saved_home)
        else
          System.delete_env("HOME")
        end

        File.rm_rf!(tmp_home)
      end
    end

    test "no rung resolves" do
      tmp_home = mktemp_dir!()

      saved_home = System.get_env("HOME")
      System.put_env("HOME", tmp_home)

      try do
        if File.exists?("/var/run/docker.sock") do
          # Cannot satisfy "neither default exists" on this host — skip body.
          :ok
        else
          assert EngineEndpoint.from_options([]) === {:error, :endpoint_not_resolved}
        end
      after
        if saved_home do
          System.put_env("HOME", saved_home)
        else
          System.delete_env("HOME")
        end

        File.rm_rf!(tmp_home)
      end
    end

    test "options[:endpoint] wins over options[:host]" do
      ep = %EngineEndpoint{
        minty: %MintyEndpoint{transport: :unix, socket_path: "/z.sock"},
        version: "1.45"
      }

      assert {:ok, ^ep} = EngineEndpoint.from_options(endpoint: ep, host: "tcp://other:9999")
    end

    test "options always beat env" do
      System.put_env("DOCKER_HOST", "tcp://envhost:9999")
      assert {:ok, ep} = EngineEndpoint.from_options(host: "tcp://opthost:1234")
      assert ep.minty.host === "opthost"
      assert ep.minty.port === 1234
    end
  end

  # ===========================================================================
  # from_options/1 — TLS resolution
  # ===========================================================================

  describe "from_options/1 TLS resolution" do
    test "with DOCKER_TLS_VERIFY=1 and DOCKER_CERT_PATH it loads TLS material and forces https" do
      System.put_env("DOCKER_HOST", "tcp://h:2376")
      System.put_env("DOCKER_TLS_VERIFY", "1")
      System.put_env("DOCKER_CERT_PATH", "/etc/d")

      assert {:ok, ep} = EngineEndpoint.from_options([])
      assert ep.minty.scheme === :https
      assert ep.minty.port === 2376

      assert ep.minty.tls === %{
               verify: :verify_peer,
               cacertfile: "/etc/d/ca.pem",
               certfile: "/etc/d/cert.pem",
               keyfile: "/etc/d/key.pem"
             }
    end

    test "accepts DOCKER_TLS_VERIFY=true (in addition to =1)" do
      System.put_env("DOCKER_HOST", "tcp://h:2376")
      System.put_env("DOCKER_TLS_VERIFY", "true")
      System.put_env("DOCKER_CERT_PATH", "/etc/d")

      assert {:ok, ep} = EngineEndpoint.from_options([])
      assert ep.minty.scheme === :https
      assert ep.minty.tls.verify === :verify_peer
      assert ep.minty.tls.cacertfile === "/etc/d/ca.pem"
    end

    test "leaves scheme as :http and tls as nil when DOCKER_TLS_VERIFY is unset" do
      System.put_env("DOCKER_HOST", "tcp://h:2375")

      assert {:ok, ep} = EngineEndpoint.from_options([])
      assert ep.minty.scheme === :http
      assert ep.minty.tls === nil
    end

    test "builds tls map with nil files when DOCKER_CERT_PATH is unset" do
      System.put_env("DOCKER_HOST", "tcp://h:2376")
      System.put_env("DOCKER_TLS_VERIFY", "1")

      assert {:ok, ep} = EngineEndpoint.from_options([])

      assert ep.minty.tls === %{
               verify: :verify_peer,
               cacertfile: nil,
               certfile: nil,
               keyfile: nil
             }
    end

    test "options[:tls] overrides env-derived TLS" do
      System.put_env("DOCKER_TLS_VERIFY", "1")
      System.put_env("DOCKER_CERT_PATH", "/etc/d")

      override = %{
        verify: :verify_none,
        cacertfile: nil,
        certfile: nil,
        keyfile: nil
      }

      assert {:ok, ep} =
               EngineEndpoint.from_options(host: "tcp://h:2376", tls: override)

      assert ep.minty.tls === override
    end

    test "options[:tls] upgrades scheme to :https and defaults port to 2376" do
      tls = %{
        verify: :verify_peer,
        cacertfile: "/c/ca.pem",
        certfile: "/c/c.pem",
        keyfile: "/c/k.pem"
      }

      assert {:ok, ep} = EngineEndpoint.from_options(host: "tcp://h", tls: tls)
      assert ep.minty.scheme === :https
      assert ep.minty.port === 2376
      assert ep.minty.tls === tls
    end
  end

  # ===========================================================================
  # from_options/1 — :version override
  # ===========================================================================

  describe "from_options/1 :version override" do
    test "options[:version] overrides resolved endpoint version" do
      assert {:ok, ep} =
               EngineEndpoint.from_options(host: "tcp://h:2375", version: "1.46")

      assert ep.version === "1.46"
    end

    test "options[:version] overrides version on unix endpoint" do
      assert {:ok, ep} =
               EngineEndpoint.from_options(socket: "/tmp/d.sock", version: "1.46")

      assert ep.version === "1.46"
    end

    test "missing :version keeps the module default" do
      assert {:ok, ep} = EngineEndpoint.from_options(socket: "/tmp/d.sock")
      assert ep.version === "1.45"
    end
  end

  # ===========================================================================
  # from_options/1 — error cases
  # ===========================================================================

  describe "from_options/1 error cases" do
    test "ssh:// in options[:host] surfaces the underlying Sorrel parse error" do
      # ssh:// URLs are now accepted by the underlying Sorrel parser, but the
      # URL alone is not enough — the caller must supply a `:target` option
      # (and optionally `:ssh`, `:user`) to Sorrel. Engine.Endpoint does not
      # forward those options today, so the parse always sees a missing
      # target. This test pins the error shape callers see: a structured
      # {:invalid_url, :missing_ssh_target} tuple, not the old blanket
      # `:ssh_not_supported`.
      assert EngineEndpoint.from_options(host: "ssh://me@h") ===
               {:error, {:invalid_url, :missing_ssh_target}}
    end

    test "malformed options[:host] returns {:invalid_url, _}" do
      assert {:error, {:invalid_url, _}} = EngineEndpoint.from_options(host: "not a url")
    end
  end

  # ===========================================================================
  # from_env/1
  # ===========================================================================

  describe "from_env/1" do
    test "is equivalent to from_options([])" do
      System.put_env("DOCKER_HOST", "tcp://envhost:2375")
      assert EngineEndpoint.from_env([]) === EngineEndpoint.from_options([])
    end

    test "option-only rungs are skipped (host option is ignored)" do
      System.put_env("DOCKER_HOST", "tcp://envhost:2375")
      assert {:ok, ep} = EngineEndpoint.from_env(host: "tcp://opthost:1234")
      assert ep.minty.host === "envhost"
      assert ep.minty.port === 2375
    end
  end

  # ===========================================================================
  # to_minty/1
  # ===========================================================================

  describe "to_minty/1" do
    test "returns the wrapped Sorrel endpoint" do
      minty = %MintyEndpoint{transport: :unix, socket_path: "/x"}
      ep = %EngineEndpoint{minty: minty, version: "1.45"}

      assert EngineEndpoint.to_minty(ep) === minty
    end

    test "the returned Sorrel endpoint has no :version field" do
      assert {:ok, ep} = EngineEndpoint.from_options(socket: "/tmp/d.sock")
      minty = EngineEndpoint.to_minty(ep)

      refute Map.has_key?(minty, :version)
    end
  end

  # ===========================================================================
  # version/1
  # ===========================================================================

  describe "version/1" do
    test "returns the version string" do
      ep = %EngineEndpoint{
        minty: %MintyEndpoint{transport: :unix, socket_path: "/x"},
        version: "1.46"
      }

      assert EngineEndpoint.version(ep) === "1.46"
    end

    test "returns the default when from_options/1 wasn't given a version" do
      assert {:ok, ep} = EngineEndpoint.from_options(socket: "/tmp/d.sock")
      assert EngineEndpoint.version(ep) === "1.45"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp mktemp_dir! do
    base =
      Path.join(
        System.tmp_dir!(),
        "docker_engine_endpoint_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    base
  end
end
