defmodule Docker.Serializer do
  @moduledoc """
  Recursively transforms Docker Engine responses into an internal "Elixir"
  shape.

  `deserialize/2` trims and unquotes incoming string keys, optionally
  normalises them through a caller-supplied `normalize_key/1` module, recases
  them (default `:snake`), and converts them to atoms. The atomization step
  delegates to `Docker.Strings.string_to_atom/2`, which owns the atom-safety
  controls (`:to_existing_atom`, `:strict`, `:allowed_keys`) for the project.
  Leaf values are passed through the optional `:transform_value` function
  unchanged otherwise.

  Traversal walks plain maps (not structs), lists, and 2-tuples (so keyword
  lists are handled). Structs and other terms are treated as leaves.

  ## Responsibilities

    - Rewrite map/keyword keys to atoms on the way in.
    - Apply caller-supplied value transforms.
    - Forward atom-safety options to `Docker.Strings.string_to_atom/2`,
      which raises rather than silently creating atoms when the configuration
      disallows them.
    - Take every normalize/transform option from the caller's `opts`.
      Atom-safety defaults live in `Docker.Strings` (see its module
      docs).

  ## Options

    * `:to_case` -- target casing for keys. Defaults to `:snake`. See
      `Docker.Casing` for the full list.
    * `:to_existing_atom`, `:strict`, `:allowed_keys` -- forwarded as-is to
      `Docker.Strings.string_to_atom/2`. See its docs for semantics and
      defaults.
    * `:normalize_key` -- a module exporting `normalize_key/1`, applied to
      each string key before recasing.
    * `:transform_value` -- a 1-arity function or `{module, function}` tuple
      applied to each leaf value.

  ## Examples

      # Deserialize incoming camelCase JSON to existing snake_case atom keys
      Docker.Serializer.deserialize(
        %{"userName" => "ada"},
        allowed_keys: ["user_name"],
        to_existing_atom: false
      )
      #=> %{user_name: "ada"}

  """

  alias Docker.Casing
  alias Docker.Strings

  # Abstraction Function:
  #   The module represents one stateless transformation:
  #     `deserialize/2` :: (term, opts) -> a same-shape tree where
  #         binary keys are normalised, recased, and atomized via
  #         `Docker.Strings.string_to_atom/2`, with leaves optionally
  #         transformed via `:transform_value`.
  #
  # Data Invariant:
  #   1. The recursive walker `transform/3` traverses three shapes:
  #      non-struct maps, lists, and 2-tuples. Structs and any other
  #      term are treated as leaves and visited by the value transform
  #      only.
  #   2. `deserialize/2`'s key transform applies in order: trim and
  #      strip `"`, optional `opts[:normalize_key].normalize_key/1`,
  #      `Casing.to_case` with `opts[:to_case]` (default `:snake`),
  #      and finally `Strings.string_to_atom/2` (forwarding atom-safety
  #      options). Non-binary keys are returned unchanged. If the
  #      normaliser returns an atom, atomization is skipped and the
  #      atom is used directly.
  #   3. `:normalize_key`, when set, must be a module exporting
  #      `normalize_key/1`. Missing modules or missing exports raise
  #      `ArgumentError`. The function's return must be `binary()` or
  #      `atom()`; any other return raises `RuntimeError`.
  #   4. `:transform_value`, when set, must be a 1-arity function or a
  #      `{module, function}` tuple. Any other value raises
  #      `ArgumentError`.
  #   5. `deserialize/2` forwards `:to_existing_atom`, `:strict`, and
  #      `:allowed_keys` to `Docker.Strings.string_to_atom/2`
  #      unchanged.
  #
  # Commutative Diagram (deserialize key path):
  #
  #   binary_key  --trim+strip-->  s1
  #         |                       |
  #         |                       | normalize_key (optional)
  #         v                       v
  #         (skip)               s2 (binary or atom)
  #                                 |
  #                                 | Casing.to_case + Strings.string_to_atom
  #                                 v
  #                              atom_key

  @doc """
  Returns an Elixir-shaped tree with atom keys derived from `term`.

  Walks plain non-struct maps, lists, and 2-tuples. Each binary key is
  trimmed, stripped of `"`, optionally normalised via
  `opts[:normalize_key].normalize_key/1`, recased through
  `Docker.Casing.to_case/3`, and atomized via
  `Docker.Strings.string_to_atom/2`. Non-binary keys are returned
  unchanged. If the normaliser returns an atom, atomization is
  skipped and that atom is used directly. Leaves are passed through
  `opts[:transform_value]` when set, otherwise unchanged.

  ## Parameters

    - `term` - `term()`. The external-shaped value to deserialize.
    - `opts` - `keyword()`. Default `[]`. Recognised keys:

        * `:to_case` - target casing for keys. Default `:snake`.
          Forwarded to `Docker.Casing.to_case/3`.
        * `:normalize_key` - module exporting `normalize_key/1`,
          applied to each string key after trimming. Must return
          binary or atom.
        * `:transform_value` - 1-arity function or `{module, function}`
          tuple applied to each leaf value.
        * `:to_existing_atom`, `:strict`, `:allowed_keys` - forwarded
          to `Docker.Strings.string_to_atom/2`. See its docs for
          atom-safety semantics.

      `opts` is also forwarded to `Docker.Casing.to_case/3` so its
      `:casing_module` key is honoured.

  ## Returns

  `term()`. A tree mirroring the input shape with binary keys
  rewritten as atoms (or whichever atom the normaliser produced) and
  leaves passed through the optional value transformer. Structs and
  non-binary keys are left untouched.

  ## Raises

    - `ArgumentError` - if `opts[:normalize_key]` is set but the
      module does not export `normalize_key/1`.
    - `ArgumentError` - if `opts[:transform_value]` is set to a value
      that is not a 1-arity function or `{module, function}` tuple.
    - `RuntimeError` - if a configured `normalize_key/1` returns
      something that is neither binary nor atom.
    - Any exception `Docker.Strings.string_to_atom/2` raises is
      propagated. Notably: `ArgumentError` from
      `String.to_existing_atom/1` when `:to_existing_atom` is `true`
      and the atom does not yet exist; `RuntimeError "Key not
      allowed: ..."` when `:strict` is `true` and the key is not in
      `:allowed_keys`.
    - Any exception `Docker.Casing.to_case/3` raises is propagated.

  ## Examples

      iex> Docker.Serializer.deserialize(
      ...>   %{"userName" => "ada"},
      ...>   to_existing_atom: false,
      ...>   strict: true,
      ...>   allowed_keys: ["user_name"]
      ...> )
      %{user_name: "ada"}

  """
  @spec deserialize(term(), keyword()) :: term()
  def deserialize(term, opts \\ []) do
    val_fun = opts[:transform_value]
    transform(term, fn key -> deserialize_key(key, opts) end, val_fun)
  end

  # Transforms a single key. Binary keys are trimmed, stripped of `"`, optionally
  # normalized, snake-cased, and atomized via Docker.Strings.string_to_atom/2.
  # Non-binary keys are returned unchanged.
  defp deserialize_key(key, opts) when is_binary(key) do
    case key |> trim_and_strip_quotes() |> normalize_key(opts) do
      string_key when is_binary(string_key) ->
        incoming_key = Casing.to_case(string_key, opts[:to_case] || :snake, opts)

        case Strings.string_to_atom(incoming_key, opts) do
          {:ok, atomized_key} -> atomized_key
          :error -> raise "Failed to deserialize key: #{incoming_key}"
        end

      skipped_key when is_atom(skipped_key) ->
        skipped_key
    end
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

  # Applies `opts[:normalize_key].normalize_key/1` when configured; otherwise returns
  # `val` unchanged. Raises if the result is neither binary nor atom.
  defp normalize_key(val, opts) do
    case opts[:normalize_key] do
      nil ->
        val

      mod ->
        ensure_normalize_key_exported!(mod)

        case mod.normalize_key(val) do
          val when is_binary(val) -> val
          val when is_atom(val) -> val
          _ -> raise "Expected normalize_key/1 to return binary or atom, got: #{inspect(val)}"
        end
    end
  end

  # Raises `ArgumentError` if `mod` does not export `normalize_key/1`. Forces module
  # load first so the check works for modules that have not yet been referenced at runtime.
  defp ensure_normalize_key_exported!(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :normalize_key, 1) do
      :ok
    else
      raise ArgumentError, "Expected module #{mod} to implement normalize_key/1"
    end
  end
end
