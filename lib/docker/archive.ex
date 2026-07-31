defmodule Docker.Archive do
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
end
