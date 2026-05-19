defmodule Docker.NDJSON do
  @moduledoc """
  Decoder for newline-delimited JSON (NDJSON) streams.

  The Docker Engine streams `pull_image` progress and `build_image`
  output as one JSON object per line. This module turns a chunked byte
  stream into one decoded map per complete line, holding back any
  trailing partial line for the next chunk.

  ## Responsibilities

    - Split a buffer at `\\n` boundaries into complete lines plus a
      trailing partial line.
    - Decode each complete non-empty line as JSON via `JSON.decode/1`.
    - Carry the trailing partial line forward as `leftover` for the
      next call.

  ## Examples

      iex> Docker.NDJSON.decode_chunk(~s({"a":1}\\n{"b":2}\\n), "")
      {[%{"a" => 1}, %{"b" => 2}], ""}

      iex> Docker.NDJSON.decode_chunk(~s({"a":1}\\n{"b"), "")
      {[%{"a" => 1}], ~s({"b")}

      iex> Docker.NDJSON.decode_chunk(~s(:2}\\n), ~s({"b"))
      {[%{"b" => 2}], ""}
  """

  @doc """
  Decodes one chunk of an NDJSON stream into events plus leftover bytes.

  ## Parameters

    - `chunk` - `binary()`. Newly arrived bytes.
    - `buffer` - `binary()`. Bytes left over from the previous call.
      Pass `""` on the first call.

  ## Returns

  `{events, leftover}` where `events` is a list of decoded maps in
  arrival order and `leftover` is bytes that did not yet form a
  complete line. Pass `leftover` back as `buffer` on the next call.

  Lines that fail to decode as JSON are silently dropped.
  """
  @spec decode_chunk(binary(), binary()) :: {[map() | list() | term()], binary()}
  def decode_chunk(chunk, buffer) when is_binary(chunk) and is_binary(buffer) do
    combined = buffer <> chunk
    {complete_lines, leftover} = split_lines(combined)
    {Enum.flat_map(complete_lines, &decode_line/1), leftover}
  end

  @spec split_lines(binary()) :: {[binary()], binary()}
  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [only] -> {[], only}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  @spec decode_line(binary()) :: [term()]
  defp decode_line(line) do
    trimmed = String.trim(line)

    if trimmed === "" do
      []
    else
      case JSON.decode(trimmed) do
        {:ok, value} -> [value]
        {:error, _reason} -> []
      end
    end
  end
end
