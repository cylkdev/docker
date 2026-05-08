defmodule Docker.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Docker.Logger, as: DockerLogger

  describe "debug/2, warning/2, error/2" do
    test "debug/2 emits a debug-level record with prefix and message" do
      log = capture_log(fn -> assert :ok = DockerLogger.debug("svc", "hello") end)
      assert log =~ "[debug]"
      assert log =~ "[svc] hello"
    end

    test "warning/2 emits a warn-level record with prefix and message" do
      log = capture_log(fn -> assert :ok = DockerLogger.warning("svc", "uh oh") end)
      assert log =~ "[svc] uh oh"
    end

    test "error/2 emits an error-level record with prefix and message" do
      log = capture_log(fn -> assert :ok = DockerLogger.error("svc", "boom") end)
      assert log =~ "[error]"
      assert log =~ "[svc] boom"
    end
  end

  describe "log_pull_event/1" do
    test "logs a status+id event as 'id: status' at info level" do
      event = %{"status" => "Pulling fs layer", "id" => "abc123"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_pull_event(event) end)

      assert log =~ "abc123: Pulling fs layer"
    end

    test "logs a status-only event as the bare status at info level" do
      event = %{"status" => "Pulling from library/alpine"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_pull_event(event) end)

      assert log =~ "Pulling from library/alpine"
    end

    test "logs an error event at error level" do
      event = %{"error" => "manifest unknown"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_pull_event(event) end)

      assert log =~ "error: manifest unknown"
    end

    test "logs a build-style stream event by emitting the trimmed line" do
      event = %{"stream" => "Step 1/2 : FROM alpine\n"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_pull_event(event) end)

      assert log =~ "Step 1/2 : FROM alpine"
    end

    test "skips empty/whitespace-only stream lines" do
      event = %{"stream" => "   \n"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_pull_event(event) end)

      refute log =~ "stream"
    end

    test "falls back to inspect on unknown event shapes" do
      event = %{"weird" => "shape"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_pull_event(event) end)

      assert log =~ "weird"
      assert log =~ "shape"
    end

    test "never raises on non-map input" do
      assert :ok = DockerLogger.log_pull_event("not a map")
      assert :ok = DockerLogger.log_pull_event(nil)
    end
  end

  describe "log_build_event/1" do
    test "delegates to log_pull_event/1 for status+id" do
      event = %{"status" => "Downloading", "id" => "layer1"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_build_event(event) end)

      assert log =~ "layer1: Downloading"
    end

    test "logs build stream lines" do
      event = %{"stream" => "Successfully built abc\n"}

      log = capture_log(fn -> assert :ok = DockerLogger.log_build_event(event) end)

      assert log =~ "Successfully built abc"
    end
  end
end
