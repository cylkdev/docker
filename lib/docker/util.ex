defmodule Docker.Util do
  @moduledoc false

  @doc false
  @spec create_tar(binary(), binary(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def create_tar(dest_path, src_path, opts \\ []) when is_binary(dest_path) do
    create_opts = [:compressed, :dereference] ++ verbose_opts(opts, true)

    case :erl_tar.create(dest_path, entries(src_path), create_opts) do
      :ok ->
        :ok

      {:error, {name, reason}} ->
        {:error,
         ErrorMessage.internal_server_error(
           "Could not write the tar archive #{dest_path}: #{inspect(reason)}",
           %{dest_path: dest_path, src_path: src_path, path: name, reason: reason}
         )}

      {:error, reason} ->
        {:error,
         ErrorMessage.internal_server_error(
           "Could not write the tar archive #{dest_path}: #{inspect(reason)}",
           %{dest_path: dest_path, src_path: src_path, reason: reason}
         )}
    end
  end

  defp entries(src_path) do
    src_path
    |> Path.wildcard()
    |> Enum.map(fn path ->
      abs_path = Path.expand(path, File.cwd!())
      basename = Path.basename(abs_path)
      {String.to_charlist(basename), String.to_charlist(abs_path)}
    end)
  end

  defp verbose_opts(opts, default) do
    if Keyword.get(opts, :verbose, default) do
      [:verbose]
    else
      []
    end
  end

  @doc false
  def append_query_string(url, params) do
    case URI.encode_query(params) do
      "" -> url
      query -> "#{url}?#{query}"
    end
  end

  # Every list endpoint encodes `:filters` the same way before building its
  # query string, and each must surface a bad filter as an error rather than
  # letting it reach the daemon.
  @doc false
  @spec encode_filters_param(map()) :: {:ok, map()} | {:error, ErrorMessage.t()}
  def encode_filters_param(params) do
    case params[:filters] do
      nil ->
        {:ok, params}

      filters ->
        with {:ok, encoded} <- encode_filters(filters) do
          {:ok, Map.put(params, :filters, encoded)}
        end
    end
  end

  # The Engine takes `filters` as a JSON object mapping a filter name to a list
  # of string values: `{"label":["env=prod"],"status":["running"]}`. Verified
  # against a live daemon, it rejects both a map at the value level
  # (`{"label":{"env":"prod"}}`) and a top-level list (`["label=env=prod"]`)
  # with `invalid filter`, so every accepted shape has to reach that one format.
  #
  # Callers write filters four ways — the CLI's `["label=env=prod"]`, the
  # documented `[label: %{"env" => "prod"}]`, already-formatted
  # `%{label: ["env=prod"]}`, and a bare `"status=running"` — so each is
  # normalized to `%{binary() => [binary()]}` before encoding. Anything else is
  # a `:bad_request` rather than a raise from inside the traversal.
  @doc false
  @spec encode_filters(term()) :: {:ok, binary()} | {:error, ErrorMessage.t()}
  def encode_filters(filters) do
    with {:ok, normalized} <- normalize_filters(filters) do
      {:ok, JSON.encode!(normalized)}
    end
  end

  # A bare string is a single CLI-style filter.
  defp normalize_filters(filters) when is_binary(filters) do
    normalize_filters([filters])
  end

  defp normalize_filters(filters)
       when is_list(filters) or (is_map(filters) and not is_struct(filters)) do
    Enum.reduce_while(filters, {:ok, %{}}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        # Repeated names accumulate: `["label=a", "label=b"]` is two values for
        # one filter, and Docker ANDs them.
        {:ok, {name, values}} ->
          {:cont, {:ok, Map.update(acc, name, values, &(&1 ++ values))}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize_filters(filters) do
    {:error,
     ErrorMessage.bad_request(
       "Expected filters as a map, keyword list, or list of \"name=value\" " <>
         "strings, got: #{inspect(filters)}",
       %{filters: filters}
     )}
  end

  # Splits on the first `=` only, so a label value keeps its own:
  # `"label=env=prod"` is the filter `label` with value `"env=prod"`.
  defp normalize_entry(entry) when is_binary(entry) do
    case String.split(entry, "=", parts: 2) do
      [name, value] ->
        with {:ok, name} <- normalize_name(name), do: {:ok, {name, [value]}}

      [_no_equals] ->
        {:error,
         ErrorMessage.bad_request(
           "Expected filter #{inspect(entry)} to be a \"name=value\" string",
           %{filter: entry}
         )}
    end
  end

  defp normalize_entry({key, value}) do
    with {:ok, name} <- normalize_name(key),
         {:ok, values} <- normalize_values(name, value) do
      {:ok, {name, values}}
    end
  end

  defp normalize_entry(entry) do
    {:error,
     ErrorMessage.bad_request(
       "Expected a filter as a \"name=value\" string or a {name, value} pair, " <>
         "got: #{inspect(entry)}",
       %{filter: entry}
     )}
  end

  defp normalize_name(name) when is_atom(name) and not is_nil(name) and not is_boolean(name) do
    normalize_name(Atom.to_string(name))
  end

  # The Engine spells multi-word filter names with dashes (`is-task`); callers
  # write them with underscores so they stay ordinary Elixir atoms.
  defp normalize_name(name) when is_binary(name) do
    {:ok, String.replace(name, "_", "-")}
  end

  defp normalize_name(name) do
    {:error,
     ErrorMessage.bad_request(
       "Expected a filter name as a string or atom, got: #{inspect(name)}",
       %{name: name}
     )}
  end

  defp normalize_values(_name, value) when is_binary(value), do: {:ok, [value]}

  # `label: %{"env" => "prod"}` — the documented form. Routed through the list
  # clause so each pair gets the same validation.
  defp normalize_values(name, value) when is_map(value) and not is_struct(value) do
    normalize_values(name, Map.to_list(value))
  end

  defp normalize_values(name, values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_value(name, value) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_values(name, value) do
    {:error,
     ErrorMessage.bad_request(
       "Expected the value of filter #{inspect(name)} to be a string, list, " <>
         "or map, got: #{inspect(value)}",
       %{name: name, value: value}
     )}
  end

  # Already formatted, e.g. `"env=prod"`, or a bare label name that matches on
  # presence alone.
  defp normalize_value(_name, value) when is_binary(value), do: {:ok, value}

  defp normalize_value(_name, {key, value})
       when (is_binary(key) or is_atom(key)) and
              (is_binary(value) or is_atom(value) or is_number(value)) do
    {:ok, "#{key}=#{value}"}
  end

  defp normalize_value(name, value) do
    {:error,
     ErrorMessage.bad_request(
       "Expected each value of filter #{inspect(name)} to be a string or a " <>
         "{key, value} pair, got: #{inspect(value)}",
       %{name: name, value: value}
     )}
  end
end
