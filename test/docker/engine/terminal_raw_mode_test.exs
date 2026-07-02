defmodule Docker.Terminal.RawModeTest do
  use ExUnit.Case, async: true
  alias Docker.Terminal.RawMode

  test "stdin_fd/0 is 0" do
    assert RawMode.stdin_fd() == 0
  end

  test "size/0 returns a {rows, cols} tuple or an error (never raises)" do
    # Under the test runner stdin is usually not a tty, so this is typically
    # {:error, _}; on a real tty it is {:ok, {rows, cols}}. Either is valid —
    # the assertion is that the call is total and well-shaped.
    case RawMode.size() do
      {:ok, {rows, cols}} when is_integer(rows) and is_integer(cols) -> :ok
      {:error, _} -> :ok
    end
  end

  test "restore/1 rejects a wrong-sized termios blob (guards bad input)" do
    # A valid saved blob is `sizeof(struct termios)`; a short one must not be
    # applied. Round-trip restore of a real blob is covered by the Task 3
    # real-terminal gate. Here we only assert the size guard rejects garbage.
    assert_raise ArgumentError, fn -> RawMode.restore(<<0>>) end
  end
end
