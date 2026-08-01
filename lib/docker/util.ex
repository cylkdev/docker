defmodule Docker.Util do
  @moduledoc false

  @doc false
  def create_tar(dest_path, src_path, opts \\ []) when is_binary(dest_path) do
    create_opts = [:compressed, :dereference] ++ verbose_opts(opts, true)
    :erl_tar.create(dest_path, entries(src_path), create_opts)
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
