defmodule Docker.Serializer do
  @moduledoc """
  Recursively transforms Docker Engine responses into an internal "Elixir"
  shape.

  `deserialize/2` trims and unquotes incoming string keys, recases them
  (default `:snake`), and converts them to atoms. Leaf values are passed
  through the optional `:transform_value` function unchanged otherwise.

  Keys become atoms with `String.to_atom/1`. Atoms are not garbage-collected,
  so do not hand this function keys from an untrusted source.

  Traversal walks plain maps (not structs), lists, and 2-tuples (so keyword
  lists are handled). Structs and other terms are treated as leaves.

  ## Responsibilities

    - Rewrite map/keyword keys to atoms on the way in.
    - Apply caller-supplied value transforms.

  ## Options

    * `:to_case` -- target casing for keys. Defaults to `:snake`. See
      `Docker.Casing` for the full list.
    * `:transform_value` -- a 1-arity function or `{module, function}` tuple
      applied to each leaf value.

  ## Examples

      # Deserialize incoming camelCase JSON to snake_case atom keys
      Docker.Serializer.deserialize(%{"userName" => "ada"})
      #=> %{user_name: "ada"}

  """

  alias Docker.Casing

  # Abstraction Function:
  #   The module represents one stateless transformation:
  #     `deserialize/2` :: (term, opts) -> a same-shape tree where
  #         binary keys are recased and atomized, with leaves
  #         optionally transformed via `:transform_value`.
  #
  # Data Invariant:
  #   1. The recursive walker `transform/3` traverses three shapes:
  #      non-struct maps, lists, and 2-tuples. Structs and any other
  #      term are treated as leaves and visited by the value transform
  #      only.
  #   2. `deserialize/2`'s key transform applies in order: trim and
  #      strip `"`, `Casing.to_case` with `opts[:to_case]` (default
  #      `:snake`), and finally `String.to_atom/1`. Non-binary keys are
  #      returned unchanged.
  #   3. `:transform_value`, when set, must be a 1-arity function or a
  #      `{module, function}` tuple. Any other value raises
  #      `ArgumentError`.
  #
  # Commutative Diagram (deserialize key path):
  #
  #   binary_key  --trim+strip-->  s1
  #                                 |
  #                                 | Casing.to_case + String.to_atom
  #                                 v
  #                              atom_key

  @doc """
  Returns an Elixir-shaped tree with atom keys derived from `term`.

  Walks plain non-struct maps, lists, and 2-tuples. Each binary key is
  trimmed, stripped of `"`, recased through `Docker.Casing.to_case/3`,
  and atomized with `String.to_atom/1`. Non-binary keys are returned
  unchanged. Leaves are passed through `opts[:transform_value]` when
  set, otherwise unchanged.

  ## Parameters

    - `term` - `term()`. The external-shaped value to deserialize.
    - `opts` - `keyword()`. Default `[]`. Recognised keys:

        * `:to_case` - target casing for keys. Default `:snake`.
          Forwarded to `Docker.Casing.to_case/3`.
        * `:transform_value` - 1-arity function or `{module, function}`
          tuple applied to each leaf value.

      `opts` is also forwarded to `Docker.Casing.to_case/3` so its
      `:casing_module` key is honoured.

  ## Returns

  `term()`. A tree mirroring the input shape with binary keys
  rewritten as atoms and leaves passed through the optional value
  transformer. Structs and non-binary keys are left untouched.

  ## Raises

    - `ArgumentError` - if `opts[:transform_value]` is set to a value
      that is not a 1-arity function or `{module, function}` tuple.
    - Any exception `Docker.Casing.to_case/3` raises is propagated.

  ## Examples

      iex> Docker.Serializer.deserialize(%{"userName" => "ada"})
      %{user_name: "ada"}

  """
  @spec deserialize(term(), keyword()) :: term()
  def deserialize(term, opts \\ []) do
    val_fun = opts[:transform_value]
    transform(term, fn key -> deserialize_key(key, opts) end, val_fun)
  end

  # Transforms a single key. Binary keys are trimmed, stripped of `"`, snake-cased,
  # and atomized. Non-binary keys are returned unchanged.
  defp deserialize_key(key, opts) when is_binary(key) do
    key
    |> trim_and_strip_quotes()
    |> Casing.to_case(opts[:to_case] || :snake, opts)
    |> String.to_atom()
  end

  defp deserialize_key(key, _opts), do: key

  defp trim_and_strip_quotes(key) do
    key |> String.trim() |> String.replace("\"", "")
  end

  # Recursive worker. Walks non-struct maps, lists, and 2-tuples; applies `key_fun` to
  # keys and `val_fun` to leaf values reached at the bottom of the traversal.
  defp transform(map, key_fun, val_fun) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, val} ->
      {key_fun.(key), transform(val, key_fun, val_fun)}
    end)
  end

  defp transform([], _key_fun, _val_fun) do
    []
  end

  defp transform([head | tail], key_fun, val_fun) do
    [transform(head, key_fun, val_fun) | transform(tail, key_fun, val_fun)]
  end

  defp transform({key, val}, key_fun, val_fun) do
    {key_fun.(key), transform(val, key_fun, val_fun)}
  end

  defp transform(val, _key_fun, val_fun) do
    apply_transform(val, val_fun)
  end

  # Applies a value transform: `nil` is a no-op, a 1-arity function is invoked,
  # an `{atom, atom}` tuple is invoked via `apply/3`.
  defp apply_transform(val, nil), do: val

  defp apply_transform(val, fun) when is_function(fun, 1) do
    fun.(val)
  end

  defp apply_transform(val, {mod, fun})
       when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [val])
  end

  defp apply_transform(_val, term) do
    raise ArgumentError,
          "Expected transform_value to be a 1-arity function or {module, function}, got: #{inspect(term)}"
  end
end
