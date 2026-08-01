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

  @doc false
  def encode_filters(filters) do
    filters
    |> Map.new(fn
      {:label, labels} -> {"label", Enum.map(labels, fn {k, v} -> "#{k}=#{v}" end)}
      {key, value} -> {key |> to_string() |> String.replace("_", "-"), value}
    end)
    |> JSON.encode!()
  end
end
