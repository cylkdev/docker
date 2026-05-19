defmodule Docker.FrameTest do
  use ExUnit.Case, async: true

  alias Docker.Frame

  describe "demux/1" do
    test "decodes a single complete stdout frame" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hello">>
      assert Frame.demux(buf) === {"hello", "", ""}
    end

    test "decodes a single complete stderr frame" do
      buf = <<2, 0, 0, 0, 0, 0, 0, 3, "err">>
      assert Frame.demux(buf) === {"", "err", ""}
    end

    test "concatenates multiple frames in order" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>
      assert Frame.demux(buf) === {"hello", "err", ""}
    end

    test "returns leftover for a partial trailing frame" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hel">>
      assert Frame.demux(buf) === {"", "", buf}
    end

    test "returns leftover when only the header has arrived" do
      buf = <<1, 0, 0, 0>>
      assert Frame.demux(buf) === {"", "", buf}
    end

    test "drops frames with unknown stream IDs" do
      buf = <<7, 0, 0, 0, 0, 0, 0, 1, "x", 1, 0, 0, 0, 0, 0, 0, 1, "y">>
      assert Frame.demux(buf) === {"y", "", ""}
    end

    test "returns triple of empties for an empty buffer" do
      assert Frame.demux("") === {"", "", ""}
    end
  end

  describe "decode_chunk/2" do
    test "decodes a single complete stdout frame" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hello">>
      assert Frame.decode_chunk(buf, "") === {[{:stdout, "hello"}], ""}
    end

    test "decodes a single complete stderr frame" do
      buf = <<2, 0, 0, 0, 0, 0, 0, 3, "err">>
      assert Frame.decode_chunk(buf, "") === {[{:stderr, "err"}], ""}
    end

    test "emits multiple events from one chunk in arrival order" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>
      assert Frame.decode_chunk(buf, "") === {[{:stdout, "hello"}, {:stderr, "err"}], ""}
    end

    test "partial header (5 of 8 header bytes) emits no events and buffers" do
      buf = <<1, 0, 0, 0, 0>>
      assert Frame.decode_chunk(buf, "") === {[], buf}
    end

    test "partial payload (header complete, payload short) emits no events and buffers" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hel">>
      assert Frame.decode_chunk(buf, "") === {[], buf}
    end

    test "header in a previous chunk completes when payload arrives" do
      header_only = <<1, 0, 0, 0, 0, 0, 0, 5>>
      assert {[], ^header_only} = Frame.decode_chunk(header_only, "")

      payload_chunk = "hello"
      assert Frame.decode_chunk(payload_chunk, header_only) === {[{:stdout, "hello"}], ""}
    end

    test "drops frames with unknown stream IDs" do
      buf = <<7, 0, 0, 0, 0, 0, 0, 1, "x", 1, 0, 0, 0, 0, 0, 0, 1, "y">>
      assert Frame.decode_chunk(buf, "") === {[{:stdout, "y"}], ""}
    end

    test "empty chunk plus empty buffer yields empty events and empty leftover" do
      assert Frame.decode_chunk("", "") === {[], ""}
    end
  end

  describe "demux_all/1" do
    test "concatenates payloads of all complete frames" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 2, 0, 0, 0, 0, 0, 0, 3, "err">>
      assert Frame.demux_all(buf) === "helloerr"
    end

    test "appends a partial trailing frame verbatim (legacy compat)" do
      buf = <<1, 0, 0, 0, 0, 0, 0, 5, "hello", 1, 0, 0>>
      assert Frame.demux_all(buf) === "hello" <> <<1, 0, 0>>
    end

    test "returns empty for an empty body" do
      assert Frame.demux_all("") === ""
    end
  end
end
