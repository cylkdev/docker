defmodule Docker.Util do
  @moduledoc false

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
