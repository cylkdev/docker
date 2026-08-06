defmodule Docker.UtilTest do
  @moduledoc """
  Covers `encode_filters/1`'s accepted input shapes.

  The Engine takes `filters` as a JSON object mapping a filter name to a list
  of string values. Verified against a live daemon: `{"label":["env=prod"]}`
  matches, while `{"label":{"env":"prod"}}` and a top-level `["label=env=prod"]`
  are both rejected with `invalid filter`. So every shape below has to arrive at
  that one wire format.

  Labels are written as a map. The `"env=prod"` string is still accepted as a
  value because that is what the Engine requires and what the Python and Go
  SDKs hand over, but the CLI's flat `["label=env=prod"]` is not an API shape
  and is rejected.
  """

  use ExUnit.Case, async: true

  alias Docker.Util

  defp encode(filters) do
    case Util.encode_filters(filters) do
      {:ok, json} -> {:ok, JSON.decode!(json)}
      {:error, error} -> {:error, error}
    end
  end

  describe "encode_filters/1 rejects the CLI's argv form" do
    test "a flat \"name=value\" entry is an error, not a parse" do
      assert {:error, %ErrorMessage{code: :bad_request} = error} = encode(["label=env=prod"])
      assert error.message =~ ~s|label: %{"env" => "prod"}|
    end

    test "a bare string is an error" do
      assert {:error, %ErrorMessage{code: :bad_request}} = encode("status=running")
    end

    test "the error names the offending entry" do
      assert {:error, %ErrorMessage{} = error} = encode(["status=running"])
      assert error.message =~ "status=running"
      assert error.details === %{filter: "status=running"}
    end
  end

  describe "encode_filters/1 with repeated names" do
    test "merges into one list rather than dropping either" do
      assert {:ok, %{"label" => ["env=prod", "tier=worker"]}} =
               encode(label: %{"env" => "prod"}, label: %{"tier" => "worker"})
    end
  end

  describe "encode_filters/1 with the documented keyword form" do
    test "joins a label map into k=v strings" do
      assert {:ok, %{"label" => ["env=prod"]}} = encode(label: %{"env" => "prod"})
    end

    test "joins every pair of a multi-entry label map" do
      assert {:ok, %{"label" => labels}} =
               encode(label: %{"env" => "staging", "tier" => "worker"})

      assert Enum.sort(labels) === ["env=staging", "tier=worker"]
    end

    test "passes a list of strings through" do
      assert {:ok, %{"status" => ["running"]}} = encode(status: ["running"])
    end

    test "combines a label map with another filter" do
      assert {:ok, %{"label" => ["tier=worker"], "status" => ["running"]}} =
               encode(label: %{"tier" => "worker"}, status: ["running"])
    end

    test "accepts a map instead of a keyword list" do
      assert {:ok, %{"status" => ["running"]}} = encode(%{status: ["running"]})
    end

    test "accepts string keys" do
      assert {:ok, %{"label" => ["name"]}} = encode(%{"label" => ["name"]})
    end

    test "rewrites underscores in filter names to dashes" do
      assert {:ok, %{"is-task" => ["true"]}} = encode(is_task: ["true"])
    end

    test "accepts a bare string value" do
      assert {:ok, %{"status" => ["running"]}} = encode(status: "running")
    end
  end

  describe "encode_filters/1 with label values already formatted" do
    test "accepts a list of k=v strings under :label" do
      assert {:ok, %{"label" => ["env=prod"]}} = encode(%{label: ["env=prod"]})
    end

    test "accepts a keyword list of labels" do
      assert {:ok, %{"label" => ["env=prod"]}} = encode(label: [env: "prod"])
    end

    test "accepts a label name with no value, which matches on presence" do
      assert {:ok, %{"label" => ["env"]}} = encode(%{label: ["env"]})
    end
  end

  describe "encode_filters/1 error handling" do
    test "returns bad_request rather than raising for a non-enumerable" do
      assert {:error, %ErrorMessage{code: :bad_request}} = encode(42)
    end

    test "returns bad_request for a bare list entry" do
      assert {:error, %ErrorMessage{code: :bad_request} = error} = encode(["label"])
      assert error.message =~ "label"
    end

    test "returns bad_request for a value that is neither string, list, nor map" do
      assert {:error, %ErrorMessage{code: :bad_request}} = encode(status: 42)
    end

    test "returns bad_request for a filter name that is not a string or atom" do
      assert {:error, %ErrorMessage{code: :bad_request}} = encode(%{42 => ["x"]})
    end

    test "names the offending value in the message" do
      assert {:error, %ErrorMessage{} = error} = encode(42)
      assert error.message =~ "42"
    end
  end
end
