defmodule Docker.Config do
  @moduledoc """
  The project's configuration surface.

  Every configurable value lives in `config/config.exs` — including the
  values that come from OS environment variables, which are read there
  and only there. This module is the only module that reads application
  configuration; the rest of the codebase calls the named functions
  below instead of `Application` or `System`.

  Reads fail loudly: a key missing from `config/config.exs` raises
  rather than silently defaulting.
  """

  @app :docker

  @doc "The OTP application these values are configured under."
  @spec app() :: atom()
  def app, do: @app

  @doc """
  Docker Engine API version prefixed onto request paths, e.g. `"1.45"`.
  """
  @spec version() :: String.t()
  def version, do: fetch!(:version)

  @doc """
  The local daemon socket path.
  """
  @spec socket_path() :: String.t()
  def socket_path, do: fetch!(:socket_path)

  defp fetch!(key), do: Application.fetch_env!(@app, key)
end
