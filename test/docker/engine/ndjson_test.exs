defmodule Docker.NDJSONTest do
  use ExUnit.Case, async: true

  alias Docker.NDJSON

  doctest Docker.NDJSON

  describe "decode_chunk/2" do
    test "decodes complete lines and holds back a partial one" do
      assert NDJSON.decode_chunk(~s({"a":1}\n{"b), "") === {[%{"a" => 1}], ~s({"b)}
    end

    test "resumes from the buffer on the next call" do
      {events, leftover} = NDJSON.decode_chunk(~s({"a":1}\n{"b), "")
      assert events === [%{"a" => 1}]

      assert NDJSON.decode_chunk(~s(":2}\n), leftover) === {[%{"b" => 2}], ""}
    end

    test "skips blank lines between records" do
      assert NDJSON.decode_chunk(~s({"a":1}\n\n{"b":2}\n), "") ===
               {[%{"a" => 1}, %{"b" => 2}], ""}
    end

    test "returns no events for an empty chunk and empty buffer" do
      assert NDJSON.decode_chunk("", "") === {[], ""}
    end

    test "raises on a malformed line rather than dropping the event" do
      assert_raise JSON.DecodeError, fn ->
        NDJSON.decode_chunk("{not json}\n", "")
      end
    end

    test "raises even when the malformed line is surrounded by valid ones" do
      assert_raise JSON.DecodeError, fn ->
        NDJSON.decode_chunk(~s({"a":1}\nbroken\n{"b":2}\n), "")
      end
    end
  end
end
