defmodule Docker.Strings do
  @moduledoc """
  String utilities for `Docker`.

  This module owns the project's safe atom-creation primitive. Atoms are not
  garbage-collected on the BEAM, so any code path that turns external strings
  (JSON keys, query parameters, message fields) into atoms risks exhausting
  the atom table if it does not gate that creation.

  Two levers control `string_to_atom/2`:

    * `:to_existing_atom` — when `true`, only converts a key to an atom
      that already exists. Defaults to `false`.
    * `:atomizeable_keys` — an allow-list of strings permitted to become
      new atoms. Accepted shapes: `:all` (no gating), `MapSet.t()`,
      `list()` (normalised to a `MapSet`), or `nil` (treat as absent and
      fall back to compile-time config). An empty list is a valid
      allow-list that rejects every key.


  `string_to_atom/2` returns `{:ok, atom()}` on success and
  `:error` when either `:to_existing_atom` is `true`
  and the atom does not exist, or the key is not in the resolved
  allow-list. The default behaviour with no opts and no config is
  `:to_existing_atom: false` plus `:atomizeable_keys` resolving to
  `:all`, i.e. `string_to_atom/2` mints freely. Callers handling
  untrusted input MUST opt in to one of the gates.

  ## Examples

      iex> _ = :mcp_string_doctest_existing
      iex> Docker.Strings.string_to_atom("mcp_string_doctest_existing", to_existing_atom: true)
      {:ok, :mcp_string_doctest_existing}

      iex> Docker.Strings.string_to_atom(
      ...>   "mcp_string_doctest_minted",
      ...>   atomizeable_keys: ["mcp_string_doctest_minted"]
      ...> )
      {:ok, :mcp_string_doctest_minted}

      iex> Docker.Strings.string_to_atom("blocked", atomizeable_keys: ["other"])
      :error

  """

  @app :shared_utils

  # Abstraction Function:
  #   The module represents a stateless gate over `String.to_atom/1`
  #   and `String.to_existing_atom/1`, parameterised by an atom-safety
  #   policy (`:to_existing_atom`, `:atomizeable_keys`).
  #
  # Data Invariant:
  #   1. `:atomizeable_keys` is resolved at call time by taking the
  #      first truthy value of:
  #        a. `opts[:atomizeable_keys]`,
  #        b. `Application.get_env(:mcp, :atomizeable_keys)`,
  #        c. `:all`.
  #      The resolved value is normalised:
  #        - `:all` is kept as `:all`;
  #        - `%MapSet{}` is kept as-is;
  #        - `list()` (including `[]`) becomes `MapSet.new(list)`;
  #        - anything else raises `ArgumentError`.
  #   2. `:to_existing_atom === true` short-circuits to
  #      `String.to_existing_atom/1`. On success the function returns
  #      `{:ok, atom}`; on `ArgumentError` it returns
  #      `:error`. `:atomizeable_keys` is not
  #      consulted in this branch.
  #   3. With `:to_existing_atom === false` (the default) and resolved
  #      `:atomizeable_keys === :all`, the function returns
  #      `{:ok, String.to_atom(key)}` with no gating.
  #   4. With `:to_existing_atom === false` and a `MapSet`, the
  #      function returns `{:ok, String.to_atom(key)}` if `key` is a
  #      member and `:error` otherwise. An empty
  #      `MapSet` rejects every key.
  #   5. `key` must be `binary()` and `opts` must be a `list()`
  #      (enforced by the function head guards).

  @doc """
  Looks up or mints the atom corresponding to `key`, gated by the
  atom-safety policy.

  Dispatch (first match wins):

    1. If `opts[:to_existing_atom]` is `true`, returns
       `{:ok, String.to_existing_atom(key)}` when the atom exists,
       `:error` otherwise. `:atomizeable_keys` is
       not consulted in this branch.
    2. Otherwise the function resolves `:atomizeable_keys` (see module
       docs for the lookup order) and:
         - if it resolves to `:all`, returns
           `{:ok, String.to_atom(key)}`;
         - if it resolves to a `MapSet`, returns
           `{:ok, String.to_atom(key)}` when `key` is a member, and
           `:error` otherwise.

  ## Parameters

    - `key` — `binary()`. The string to convert.
    - `opts` — `keyword()`. Recognised keys:

        * `:to_existing_atom` — `boolean()`. Defaults to `false`. When
          `true`, only converts to an existing atom.
        * `:atomizeable_keys` — `:all | MapSet.t() | list() | nil`.
          Allow-list of keys that may mint new atoms. `:all` disables
          gating. Lists are normalised to a `MapSet`; an empty list
          rejects every key. `nil` (the default) means "fall back to
          `Application.get_env(:mcp, :atomizeable_keys)`, then to `:all`". Any other
          value raises `ArgumentError`.

      Unknown keys in `opts` are ignored.

  ## Returns

    - `{:ok, atom()}` on success.
    - `:error` when `:to_existing_atom` is `true`
      and the atom does not exist, or when a non-`:all` allow-list
      is in effect and `key` is not a member.

  ## Raises

    - `ArgumentError "Expected :atomizeable_keys to be :all,
      MapSet.t(), or a list, got: <inspect>"` — when the resolved
      `:atomizeable_keys` value is not one of `:all`, `MapSet.t()`,
      or `list()`. This is a programming error, not a lookup failure.
    - `FunctionClauseError` — when `key` is not a binary or `opts`
      is not a list.

  ## Examples

      iex> Docker.Strings.string_to_atom("Elixir.Enum", to_existing_atom: true)
      {:ok, Enum}

      iex> Docker.Strings.string_to_atom("non_existing_atom", atomizeable_keys: ["non_existing_atom"])
      {:ok, :non_existing_atom}

      iex> Docker.Strings.string_to_atom("blocked", atomizeable_keys: ["other"])
      :error

  """
  @spec string_to_atom(binary(), keyword()) ::
          {:ok, atom()} | :error
  def string_to_atom(key, opts) when is_binary(key) and is_list(opts) do
    if Keyword.get(opts, :to_existing_atom, false) do
      try do
        {:ok, String.to_existing_atom(key)}
      rescue
        _ -> :error
      end
    else
      case get_atomizable_keys(opts) do
        :all ->
          {:ok, String.to_atom(key)}

        atomizable_keys ->
          if not MapSet.member?(atomizable_keys, key) do
            :error
          else
            {:ok, String.to_atom(key)}
          end
      end
    end
  end

  defp get_atomizable_keys(opts) do
    case opts[:atomizeable_keys] || Application.get_env(@app, :atomizeable_keys) || :all do
      :all ->
        :all

      %MapSet{} = set ->
        set

      list when is_list(list) ->
        MapSet.new(list)

      other ->
        raise ArgumentError,
              "Expected :atomizeable_keys to be :all, MapSet.t(), or a list, got: #{inspect(other)}"
    end
  end
end
