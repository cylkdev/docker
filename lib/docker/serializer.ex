defmodule Docker.Serializer do
  @moduledoc """
  Recursively transforms Elixir data structures between an internal "Elixir"
  shape and an external "wire" shape.

  `serialize/2` rewrites map and keyword keys into a string casing suitable for
  transport (default `:camel`) and coerces leaf values into JSON-friendly
  terms via `Docker.Serializer.to_serial_term/2` (or a caller-supplied
  transformer).

  `deserialize/2` is the inverse for keys: it trims and unquotes incoming
  string keys, optionally normalises them through a caller-supplied
  `normalize_key/1` module, recases them (default `:snake`), and converts them
  to atoms. The atomization step delegates to
  `Docker.Strings.string_to_atom/2`, which owns the atom-safety controls
  (`:to_existing_atom`, `:strict`, `:allowed_keys`) for the project.
  Leaf values are passed through the optional `:transform_value` function
  unchanged otherwise.

  Traversal walks plain maps (not structs), lists, and 2-tuples (so keyword
  lists are handled). Structs and other terms are treated as leaves.

  ## Responsibilities

    - Rewrite map/keyword keys to a target casing on the way out (`serialize`)
      and back to atoms on the way in (`deserialize`).
    - Coerce non-JSON-able leaf values during serialization via a configurable
      transformer (defaults to `Docker.Serializer.to_serial_term/2`).
    - Apply caller-supplied value transforms during deserialization.
    - Forward atom-safety options to `Docker.Strings.string_to_atom/2`,
      which raises rather than silently creating atoms when the configuration
      disallows them.
    - Read defaults for normalize/transform options from compile-time
      configuration under `config :mcp, :serializer, ...`, with
      per-call `opts` overriding them. Atom-safety defaults live in
      `Docker.Strings` (see its module docs).

  ## Options

    * `:to_case` -- target casing for keys. Defaults to `:camel` for
      `serialize/2` and `:snake` for `deserialize/2`. See `Docker.Casing` for
      the full list.
    * `:to_existing_atom`, `:strict`, `:allowed_keys` -- forwarded as-is to
      `Docker.Strings.string_to_atom/2`. See its docs for semantics and
      defaults.
    * `:normalize_key` -- a module exporting `normalize_key/1`, applied to
      each string key before recasing during deserialization.
    * `:transform_value` -- a 1-arity function or `{module, function}` tuple
      applied to each leaf value. On `serialize/2` it overrides the JSON
      coercion; on `deserialize/2` it transforms incoming leaves.
    * `:to_serial_term` -- the value coercion strategy used by `serialize/2`
      when `:transform_value` is not set. Accepts a module, a 2-arity
      function, or a `{module, function}` tuple. Defaults to `Docker.JSON`.

  ## Examples

      # Serialize a struct-free map to camelCase string keys
      Docker.Serializer.serialize(%{user_name: "ada", joined_at: ~D[2026-05-02]})
      #=> %{"userName" => "ada", "joinedAt" => "2026-05-02"}

      # Deserialize incoming camelCase JSON to existing snake_case atom keys
      Docker.Serializer.deserialize(
        %{"userName" => "ada"},
        allowed_keys: [\"user_name\"],
        to_existing_atom: false
      )
      #=> %{user_name: "ada"}

  """

  alias Docker.Casing
  alias Docker.Strings

  @app :shared_utils

  # Abstraction Function:
  #   The module represents three stateless transformations:
  #     `to_serial_term/2` :: (term, opts) -> JSON-friendly term, by
  #         pattern-matching on a fixed set of non-JSON Elixir leaf
  #         types (PIDs, dates, structs, anonymous functions).
  #     `serialize/2` :: (term, opts) -> a same-shape tree where map
  #         and 2-tuple keys are stringified and recased, leaves are
  #         coerced via `dump_term!/2`.
  #     `deserialize/2` :: (term, opts) -> a same-shape tree where
  #         binary keys are normalised, recased, and atomized via
  #         `Docker.Strings.string_to_atom/2`, with leaves optionally
  #         transformed via `:transform_value`.
  #   `@default_options` represents the static options applied before
  #   compile-time configuration. `@compiled_options` holds compile-time
  #   `config :mcp, :serializer, ...` overrides.
  #   `default_options()` is their merge.
  #
  # Data Invariant:
  #   1. Per-call `opts` are merged on top of `default_options()` so
  #      caller keys always win over compile-time config.
  #   2. The recursive walker `transform/3` traverses three shapes:
  #      non-struct maps, lists, and 2-tuples. Structs and any other
  #      term are treated as leaves and visited by the value transform
  #      only.
  #   3. `serialize/2`'s key transform stringifies atom keys via
  #      `Atom.to_string/1`, passes binary keys through, and forwards
  #      everything to `Casing.to_case/3` with `opts[:to_case]` (or
  #      `:camel` when absent).
  #   4. `deserialize/2`'s key transform applies in order: trim and
  #      strip `"`, optional `opts[:normalize_key].normalize_key/1`,
  #      `Casing.to_case` with `opts[:to_case]` (default `:snake`),
  #      and finally `Strings.string_to_atom/2` (forwarding atom-safety
  #      options). Non-binary keys are returned unchanged. If the
  #      normaliser returns an atom, atomization is skipped and the
  #      atom is used directly.
  #   5. `:normalize_key`, when set, must be a module exporting
  #      `normalize_key/1`. Missing modules or missing exports raise
  #      `ArgumentError`. The function's return must be `binary()` or
  #      `atom()`; any other return raises `RuntimeError`.
  #   6. `:transform_value`, when set, must be a 1-arity function or a
  #      `{module, function}` tuple. Any other value raises
  #      `ArgumentError`.
  #   7. `serialize/2`'s value coercion uses, in priority order:
  #      `opts[:transform_value]`, otherwise `dump_term!/2`. The
  #      latter dispatches `opts[:to_serial_term]` over: a 2-arity
  #      function, a module atom (calls `mod.to_serial_term/2`), a
  #      `{module, function}` tuple (`apply/3`), or `nil` (uses this
  #      module's `to_serial_term/2`). Any other value raises
  #      `ArgumentError`.
  #   8. `to_serial_term/2`:
  #         - PIDs become `inspect(pid)`, plus `__<registered_name>`
  #           when registered.
  #         - `Date`, `Time`, `DateTime`, `NaiveDateTime` are rendered
  #           via `to_iso8601/2` with the format from
  #           `opts[:date|:time|:datetime][:format]` (default
  #           `:extended`).
  #         - Other structs become `%{struct: "<Module>", data: <map>}`
  #           with `Elixir.` stripped.
  #         - Anonymous functions become
  #           `%{module: ..., function: ..., arity: ...}`.
  #         - Any other term is returned unchanged.
  #   9. `deserialize/2` forwards `:to_existing_atom`, `:strict`, and
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

  @default_options [
    normalize_key: nil,
    transform_value: nil
  ]

  @doc """
  Returns a JSON-friendly representation of a single Elixir term.

  Matches a fixed set of non-JSON-able leaf types and falls through
  unchanged for anything else. The recursive walker in `serialize/2`
  invokes this function (or a caller-supplied alternative) on every
  leaf it reaches.

  ## Parameters

    - `term` - `term()`. The leaf to coerce. Pattern-matched in this
      order: `pid`, `Date`, `Time`, `DateTime`, `NaiveDateTime`,
      arbitrary struct, anonymous function, anything else.
    - `opts` - `keyword()`. Recognised keys:

        * `opts[:date][:format]` - ISO-8601 format passed to
          `Date.to_iso8601/2`. Default `:extended`.
        * `opts[:time][:format]` - same for `Time.to_iso8601/2`.
        * `opts[:datetime][:format]` - same for `DateTime.to_iso8601/2`
          and `NaiveDateTime.to_iso8601/2`.

      All other keys are ignored.

  ## Returns

  `term()`. The coerced representation:

    - `pid` -> `inspect(pid)`. If the pid has a registered name, the
      string is suffixed with `"__<registered_name>"`.
    - `%Date{}` / `%Time{}` / `%DateTime{}` / `%NaiveDateTime{}` ->
      ISO-8601 string at the configured format.
    - any other struct `%mod{}` -> `%{struct: "<module string>",
      data: <map of fields>}` with `"Elixir."` stripped from the
      module name.
    - anonymous function -> `%{module: <string>, function: <string>,
      arity: <integer>}`.
    - any other term -> returned unchanged.

  No global state is touched.

  ## Examples

      iex> Docker.Serializer.to_serial_term(~D[2026-05-02], [])
      "2026-05-02"

      iex> Docker.Serializer.to_serial_term(~T[10:20:30], [])
      "10:20:30"

      iex> Docker.Serializer.to_serial_term(42, [])
      42

  """
  @spec to_serial_term(term(), keyword()) :: term()
  def to_serial_term(pid, _opts) when is_pid(pid) do
    pid_string = inspect(pid)

    case Process.info(pid, :registered_name) do
      nil ->
        pid_string

      {:registered_name, []} ->
        pid_string

      {:registered_name, registered_name} ->
        "#{pid_string}__#{registered_name}"
    end
  end

  def to_serial_term(%Date{} = date, opts) do
    Date.to_iso8601(date, opts[:date][:format] || :extended)
  end

  def to_serial_term(%Time{} = time, opts) do
    Time.to_iso8601(time, opts[:time][:format] || :extended)
  end

  def to_serial_term(%DateTime{} = date_time, opts) do
    DateTime.to_iso8601(date_time, opts[:datetime][:format] || :extended)
  end

  def to_serial_term(%NaiveDateTime{} = naive_date_time, opts) do
    NaiveDateTime.to_iso8601(naive_date_time, opts[:datetime][:format] || :extended)
  end

  def to_serial_term(%module{} = struct_data, _opts) do
    %{
      struct: module |> Atom.to_string() |> String.replace("Elixir.", ""),
      data: Map.from_struct(struct_data)
    }
  end

  def to_serial_term(fun, _opts) when is_function(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)
    {:name, name} = :erlang.fun_info(fun, :name)
    {:arity, arity} = :erlang.fun_info(fun, :arity)

    %{
      module: Atom.to_string(module),
      function: Atom.to_string(name),
      arity: arity
    }
  end

  def to_serial_term(val, _opts), do: val

  @doc """
  Returns a JSON-friendly tree with recased keys derived from `term`.

  Walks plain non-struct maps, lists, and 2-tuples; rewrites every
  map and 2-tuple key to a string of the target casing; coerces
  every leaf via `dump_term!/2` (or `opts[:transform_value]` when
  set). Structs and any other term are treated as leaves.

  ## Parameters

    - `term` - `term()`. The Elixir-shaped value to serialize.
    - `opts` - `keyword()`. Default `[]`.
        * `:to_case` - target casing for keys. Default `:camel`.
          Forwarded to `Docker.Casing.to_case/3`.
        * `:transform_value` - 1-arity function or `{module, function}`
          tuple applied to each leaf instead of the default
          coercion.
        * `:to_serial_term` - module, 2-arity function, or
          `{module, function}` tuple used as the default coercion
          when `:transform_value` is not set. Default
          `Docker.Serializer` itself (i.e. `to_serial_term/2`).
        * `opts[:date][:format]`, `opts[:time][:format]`,
          `opts[:datetime][:format]` - forwarded to the date/time
          coercions in `to_serial_term/2`.

      `opts` is also forwarded to `Docker.Casing.to_case/3` so its
      `:casing_module` key is honoured.

  ## Returns

  `term()`. A tree mirroring the input shape with:

    - non-struct map keys converted via `Atom.to_string/1` (atoms),
      passed through (binaries), or left unchanged (other types),
      then recased through `Docker.Casing.to_case/3`.
    - 2-tuple first-elements treated identically.
    - leaves coerced via the resolved value transformer.

  ## Raises

    - `ArgumentError` - if `opts[:to_serial_term]` is not `nil`, a
      module atom, a 2-arity function, or a `{module, function}`
      tuple.
    - Any exception `Docker.Casing.to_case/3` raises (e.g. unknown
      casing or unsupported backend) is propagated.
    - Any exception the resolved value transformer raises is
      propagated.

  ## Examples

      iex> Docker.Serializer.serialize(%{user_name: "ada"})
      %{"userName" => "ada"}

      iex> Docker.Serializer.serialize(%{joined_at: ~D[2026-05-02]})
      %{"joinedAt" => "2026-05-02"}

  """
  @spec serialize(term(), keyword()) :: term()
  def serialize(term, opts \\ []) do
    opts = Keyword.merge(default_options(), opts)
    val_fun = opts[:transform_value]

    transform(
      term,
      fn key ->
        key
        |> serialize_key_to_string()
        |> Casing.to_case(opts[:to_case] || :camel, opts)
      end,
      fn val ->
        if is_nil(val_fun) do
          dump_term!(val, opts)
        else
          val_fun.(val)
        end
      end
    )
  end

  defp serialize_key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp serialize_key_to_string(key) when is_binary(key), do: key
  defp serialize_key_to_string(key), do: key

  defp dump_term!(val, opts) do
    case opts[:to_serial_term] do
      nil ->
        to_serial_term(val, opts)

      fun when is_function(fun, 2) ->
        fun.(val, opts)

      mod when is_atom(mod) and not is_nil(mod) ->
        mod.to_serial_term(val, opts)

      {mod, fun} ->
        apply(mod, fun, [val, opts])

      term ->
        raise ArgumentError,
              "Expected `:to_serial_term` to be an atom, function, or {module, function}, got: #{inspect(term)}"
    end
  end

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
    - `opts` - `keyword()`. Default `[]`. Merged on top of
      `default_options()`. Recognised keys:

        * `:to_case` - target casing for keys. Default `:snake`.
          Forwarded to `Docker.Casing.to_case/3`.
        * `:normalize_key` - module exporting `normalize_key/1`,
          applied to each string key after trimming. Must return
          binary or atom.
        * `:transform_value` - 1-arity function or `{module, function}`
          tuple applied to each leaf.
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
    opts = Keyword.merge(default_options(), opts)
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
       when is_atom(mod) and not is_nil(mod) and (is_atom(fun) and not is_nil(fun)) do
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

  defp default_options do
    Keyword.merge(@default_options, Application.get_env(@app, :serializer) || [])
  end
end
