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
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
