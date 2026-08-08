defmodule Docker.Image do
  @moduledoc """
  Image management for Docker containers.

  An image is a read-only template — like a snapshot of a filesystem — that
  Docker uses to create containers. Before you can create a container, its
  image must already be present on the daemon. Use this module to pull images
  from a registry, build them from a local Dockerfile, list what is available,
  or delete images you no longer need.

  Every function here is also exposed on the `Docker` facade
  (e.g. `Docker.pull_image/3`). See `Docker` for the full client overview.

  ## Example

      # Pull an image from Docker Hub (only needed once — Docker caches it)
      {:ok, stream} = Docker.Image.pull_image("alpine:3.19")
      Stream.run(stream)

      # Confirm it is now available locally
      {:ok, image} = Docker.Image.find_image("alpine:3.19")
      image["Id"]  # e.g. "sha256:abc123..."
  """

  alias Docker.Client
  alias Docker.Util

  @build_image_query_keys [
    :dockerfile,
    :t,
    :extrahosts,
    :remote,
    :q,
    :nocache,
    :cachefrom,
    :pull,
    :rm,
    :forcerm,
    :memory,
    :memswap,
    :cpushares,
    :cpusetcpus,
    :cpuperiod,
    :cpuquota,
    :buildargs,
    :shmsize,
    :squash,
    :labels,
    :networkmode,
    :platform,
    :target,
    :outputs,
    :version
  ]

  @pull_image_query_keys [
    :fromImage,
    :fromSrc,
    :repo,
    :tag,
    :message,
    :changes,
    :platform
  ]

  @doc """
  Returns a list of all images currently stored on the daemon.

  ## Parameters

    - `params` — optional map of Docker Engine query parameters:
      - `:all` — boolean. When `true`, includes intermediate build layers.
        Default: `false`.
      - `:shared_size` — boolean, include shared layer size. Sent to the
        Engine as `shared-size`.
      - `:digests` — boolean, include image digests.
      - `:manifests` — boolean, include manifest summaries.
      - `:identity` — boolean, include `Identity` per manifest. Requires
        `:manifests`.
      - `:filters` — optional. Recognised names: `:before`, `:dangling`,
        `:label`, `:reference`, `:since`, `:until`. Takes a label map
        (`[label: %{"env" => "prod"}]`), a list of strings
        (`[reference: ["alpine*"]]`), or a lone value (`[dangling: "true"]`).
        Anything else, including the CLI's `["label=env=prod"]`, returns
        `{:error, error}` with code `:bad_request`.
    - `options` — optional keyword list. See `Docker`
      for the options table.

  ## Returns

    - `{:ok, [map]}` — a list of image maps. Each map has string keys
      including `"Id"`, `"RepoTags"`, `"Size"`, and `"Created"`.
    - `{:error, error}` — an `t:ErrorMessage.t/0`.

  ## Examples

      # All locally available images
      {:ok, images} = Docker.Image.list_images()

      # Only images tagged "alpine" (any version)
      {:ok, images} = Docker.Image.list_images(%{filters: [reference: ["alpine*"]]})
  """
  @spec list_images(Docker.params(), Docker.options()) :: Docker.result(Docker.json_list())
  def list_images(params \\ %{}, options \\ []) do
    with {:ok, params} <- Util.encode_filters_param(params) do
      params = rename_shared_size_param(params)

      if sandbox?(options) do
        sandbox_list_images_response(params, options)
      else
        do_list_images(params, options)
      end
    end
  end

  # The Engine spells this query parameter `shared-size`. Callers write it
  # as `:shared_size` so the option stays an ordinary Elixir atom.
  defp rename_shared_size_param(params) do
    case Map.pop(params, :shared_size) do
      {nil, params} -> params
      {value, params} -> Map.put(params, :"shared-size", value)
    end
  end

  defp do_list_images(params, options) do
    url = Util.append_query_string("/images/json", params)

    case Client.request(:get, url, nil, options) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, %ErrorMessage{} = error} -> {:error, error}
    end
  end

  @doc """
  Returns a single image by name or ID.

  ## Parameters

    - `image_ref` — a string identifying the image. Accepted forms:
      - `"alpine:3.19"` — name and tag.
      - `"alpine"` — name only (Docker resolves to `"latest"` tag).
      - `"sha256:abc123…"` — full image ID.
      - `"abc123"` — unique ID prefix (as long as it is unambiguous).
    - `options` — optional keyword list. See `Docker` for the options table.

  ## Returns

    - `{:ok, map}` — image details map with string keys including `"Id"`,
      `"RepoTags"`, `"Size"`, `"Created"`, and `"Config"`.
    - `{:error, error}` — an `t:ErrorMessage.t/0`. `:not_found` when no
      image matched `image_ref`.

  ## Examples

      {:ok, image} = Docker.Image.find_image("alpine:3.19")
      image["Id"]       # full sha256 ID
      image["RepoTags"] # e.g. ["alpine:3.19"]

      # By ID prefix
      {:ok, image} = Docker.Image.find_image("abc123")
  """
  @spec find_image(Docker.image_ref(), Docker.options()) :: Docker.result(Docker.json_map())
  def find_image(image_ref, options \\ []) do
    if sandbox?(options) do
      sandbox_find_image_response(image_ref, options)
    else
      do_find_image(image_ref, options)
    end
  end

  defp do_find_image(image_ref, options) do
    url = "/images/#{image_ref}/json"

    case Client.request(:get, url, nil, options) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, %ErrorMessage{} = error} -> {:error, error}
    end
  end

  @doc """
  Downloads an image from a registry.

  Docker sends progress updates as it downloads each layer. This function
  returns those updates as a stream of maps — one map per event. **You must
  consume the stream** (e.g. with `Stream.run/1`) or the download will not
  complete and the connection will stay open.

  ## Parameters

    - `image` — the image to pull. Examples: `"alpine:3.19"`,
      `"ubuntu:22.04"`, `"my-registry.example.com/myapp:v2"`.
    - `params` — optional map of additional Docker Engine query parameters.
    - `options` — optional keyword list. See `Docker` for the options table.

  ## Returns

    - `{:ok, stream}` — an `Enumerable` of decoded event maps. Each map
      has a `"status"` key (e.g. `"Pulling fs layer"`, `"Pull complete"`)
      and optionally `"id"` (layer ID) and `"progressDetail"`.
    - `{:error, error}` — an `t:ErrorMessage.t/0`. `:not_found` when the
      image does not exist in the registry.

  ## Examples

      # Pull and wait for it to finish (discard events)
      {:ok, stream} = Docker.Image.pull_image("alpine:3.19")
      Stream.run(stream)

      # Pull and print progress as it downloads
      {:ok, stream} = Docker.Image.pull_image("alpine:3.19")
      stream
      |> Stream.each(fn event -> IO.puts(event["status"]) end)
      |> Stream.run()

      # Collect all events (useful in tests or for inspecting results)
      {:ok, stream} = Docker.Image.pull_image("alpine:3.19")
      events = Enum.to_list(stream)
  """
  @spec pull_image(image :: binary(), Docker.params(), Docker.options()) ::
          {:ok, Enumerable.t()} | {:error, ErrorMessage.t()}
  def pull_image(image, params \\ %{}, options \\ []) do
    if sandbox?(options) do
      sandbox_pull_image_response(image, params, options)
    else
      do_pull_image(image, params, options)
    end
  end

  defp do_pull_image(image, params, options) do
    query = params |> Map.put(:fromImage, image) |> URI.encode_query()
    url = "/images/create?" <> query
    Client.stream(:post, url, nil, Keyword.put_new(options, :into, :ndjson))
  end

  @doc """
  Builds a new image from a local Dockerfile and a build context directory.

  The *build context* is the folder you point Docker at. Docker packs
  everything in that folder into an archive and sends it to the daemon. The
  Dockerfile tells the daemon what to do with it. The Dockerfile must be
  inside the context folder (or at its root).

  Like `pull_image/3`, this returns a stream of progress events that must
  be consumed for the build to complete.

  ## Parameters

    - `context_path` — path to the build context directory on the local
      filesystem. Example: `"./my-app"` or `"/home/user/project"`.
    - `dockerfile` — path to the Dockerfile, relative to `context_path`.
      Use `"Dockerfile"` for the default location.
    - `tag` — the name and tag to give the resulting image. Example:
      `"my-app:latest"` or `"my-app:v1.2.0"`. Required.
    - `params` — optional map of additional Docker Engine build parameters.
    - `options` — optional keyword list. See `Docker` for the options table.

  ## Returns

    - `{:ok, stream}` — an `Enumerable` of decoded event maps, same format
      as `pull_image/3`. Each map has a `"stream"` key with build output
      lines (e.g. `"Step 1/3 : FROM alpine\\n"`).
    - `{:error, error}` — an `t:ErrorMessage.t/0`. `:bad_request` when
      `tag` is empty, the context path is not a directory, or the
      Dockerfile lies outside the context.

  ## Examples

      # Build from ./my-app/Dockerfile, tag the result "my-app:latest"
      {:ok, stream} = Docker.Image.build_image("./my-app", "Dockerfile", "my-app:latest")
      Stream.run(stream)

      # Print build output as it streams in
      {:ok, stream} = Docker.Image.build_image("./my-app", "Dockerfile", "my-app:latest")
      stream
      |> Stream.each(fn
        %{"stream" => line} -> IO.write(line)
        _other -> :ok
      end)
      |> Stream.run()
  """
  @spec build_image(binary(), binary(), binary(), Docker.params(), Docker.options()) ::
          {:ok, Enumerable.t()} | {:error, ErrorMessage.t()}
  def build_image(context_path, dockerfile, tag, params \\ %{}, options \\ [])
      when is_binary(tag) and is_binary(context_path) do
    cond do
      tag === "" ->
        {:error, ErrorMessage.bad_request("Expected tag to be a non-empty string", %{tag: tag})}

      sandbox?(options) ->
        sandbox_build_image_response(context_path, dockerfile, tag, params, options)

      true ->
        do_build_image(context_path, dockerfile, tag, params, options)
    end
  end

  defp do_build_image(context_path, dockerfile, tag, params, options) do
    context_path = Path.expand(context_path)

    with {:ok, dockerfile_rel} <- resolve_dockerfile_path(dockerfile, context_path),
         {:ok, tar} <- build_context_tar(context_path) do
      query =
        params
        |> Map.drop([:tag, :t])
        |> Map.merge(%{t: tag, dockerfile: dockerfile_rel})
        |> URI.encode_query()

      Client.stream(
        :post,
        "/build?" <> query,
        {:tar, tar},
        Keyword.put_new(options, :into, :ndjson)
      )
    end
  end

  @doc """
  Builds an image and consumes the resulting progress stream, printing
  build output (the `"stream"` field of each event) to standard output as
  it arrives.

  Convenience wrapper around `build_image/5` for callers who just want to
  kick off a build and watch it run, the same way `docker build` does on
  the command line. All arguments are forwarded verbatim to
  `build_image/5`.

  ## Parameters

  Same as `build_image/5`:

    - `context_path` — path to the build context directory.
    - `dockerfile` — path to the Dockerfile, relative to `context_path`.
    - `tag` — name and tag for the resulting image.
    - `params` — optional map of additional Docker Engine build parameters.
    - `options` — optional keyword list. See `Docker` for the options table.

  ## Returns

    - `:ok` — the build stream completed and the daemon reported no build
      error.
    - `{:error, error}` — an `t:ErrorMessage.t/0`, either from
      `build_image/5` failing to produce a stream or, as
      `:unprocessable_entity`, from an `"error"` event the daemon emitted
      mid-build (e.g. a failing `RUN` step).

  ## Examples

      # Equivalent of `docker build -t my-app:latest ./my-app`
      :ok = Docker.Image.run_build_image("./my-app", "Dockerfile", "my-app:latest")
  """
  @spec run_build_image(binary(), binary(), binary(), Docker.params(), Docker.options()) ::
          :ok | {:error, ErrorMessage.t()}
  def run_build_image(context_path, dockerfile, tag, params \\ %{}, options \\ []) do
    with {:ok, stream} <- build_image(context_path, dockerfile, tag, params, options) do
      Enum.reduce_while(stream, :ok, &consume_build_event/2)
    end
  end

  defp consume_build_event(%{"error" => message}, :ok) do
    {:halt,
     {:error,
      ErrorMessage.unprocessable_entity(message, %{source: :build_stream, error: message})}}
  end

  defp consume_build_event(%{"stream" => line}, :ok) do
    IO.write(line)
    {:cont, :ok}
  end

  # "aux", "status", "progressDetail" and friends carry no build output.
  defp consume_build_event(_event, :ok), do: {:cont, :ok}

  @doc """
  Returns an image if it is already present locally; otherwise builds or
  pulls it.

  This is a convenience for setup code that needs an image to be present
  regardless of whether it was previously fetched. The decision to build
  or pull is made from `image_or_path`:

    - If `image_or_path` is a path to a local file or directory that
      exists on disk, the image is **built** using that path as the build
      context (or Dockerfile location). The tag is taken from `image_ref`.
    - Otherwise, `image_or_path` is treated as a registry image name and
      **pulled**.

  ## Parameters

    - `image_ref` — the name/tag to look for locally and, if building, to
      assign to the new image. Example: `"my-app:latest"`.
    - `image_or_path` — either a local filesystem path (to build from) or a
      registry image reference (to pull). Example: `"./my-app"` or
      `"nginx:alpine"`.
    - `params` — optional map forwarded to `build_image/5` or
      `pull_image/3`.
    - `options` — optional keyword list. See `Docker` for the options table.

  ## Returns

    - `{:ok, image_map}` — the image already existed locally.
    - `{:ok, stream}` — the image was not found; a build or pull stream is
      returned. Consume it to complete the operation.
    - `{:error, error}` — an `t:ErrorMessage.t/0`. A 4xx-coded error from
      the initial lookup is treated as "not present yet" and triggers the
      build or pull; anything else is returned as-is.

  ## Examples

      # Ensure "my-app:latest" exists, building from ./my-app if needed
      case Docker.Image.materialize_image("my-app:latest", "./my-app", %{}, []) do
        {:ok, %{"Id" => id}} -> IO.puts("Already present: " <> id)
        {:ok, stream} -> Stream.run(stream)
        {:error, error} -> raise ErrorMessage.to_string(error)
      end
  """
  @spec materialize_image(Docker.image_ref(), binary(), Docker.params(), Docker.options()) ::
          {:ok, term()} | {:error, ErrorMessage.t()}
  def materialize_image(image_ref, image_or_path, params, options) do
    if sandbox?(options) do
      sandbox_materialize_image_response(image_ref, image_or_path, params, options)
    else
      do_materialize_image(image_ref, image_or_path, params, options)
    end
  end

  defp do_materialize_image(image_ref, image_or_path, params, options) do
    case find_image(image_ref, options) do
      {:ok, image} ->
        {:ok, image}

      # The image simply is not here yet — that is the case this function
      # exists to handle. Anything else (no daemon, permissions) is a real
      # failure and passes through.
      {:error, %ErrorMessage{code: code} = error} ->
        if ErrorMessage.http_code(code) in 400..499 do
          build_or_pull_image(image_ref, image_or_path, params, options)
        else
          {:error, error}
        end
    end
  end

  defp build_or_pull_image(image_ref, image_or_path, params, options) do
    if local_image_path?(image_or_path) do
      build_local_image(image_ref, image_or_path, params, options)
    else
      pull_image(image_or_path, Map.take(params, @pull_image_query_keys), options)
    end
  end

  defp build_local_image(image_ref, image_or_path, params, options) do
    with {:ok, tag} <- extract_tag(image_ref, params),
         {dockerfile, context_path} <- normalize_build_path(image_or_path) do
      build_image(
        context_path,
        dockerfile,
        tag,
        Map.take(params, @build_image_query_keys),
        options
      )
    end
  end

  defp normalize_build_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {Path.join(expanded, "Dockerfile"), expanded}
    else
      {nil, expanded}
    end
  end

  # `build_image/5` wants the *full* "name:tag" for `?t=`, so an `image_ref`
  # that already carries a tag is passed through whole. Splitting it is only
  # a presence check: an untagged ref would build as ":latest" under the
  # wrong name, so it is rejected instead.
  defp extract_tag(image_ref, params) do
    case params[:tag] || params["tag"] do
      tag when is_binary(tag) and tag !== "" ->
        {:ok, tag}

      nil ->
        case split_image_ref_tag(image_ref) do
          {_name, nil} ->
            {:error,
             ErrorMessage.bad_request(
               "Cannot build an untagged image reference — pass a `:tag` param " <>
                 "or use a \"name:tag\" reference",
               %{image_ref: image_ref}
             )}

          {_name, _tag} ->
            {:ok, image_ref}
        end
    end
  end

  defp local_image_path?(path) when is_binary(path) do
    expanded = Path.expand(path)
    File.dir?(expanded) or File.regular?(expanded)
  end

  defp resolve_dockerfile_path(dockerfile, context_path)
       when is_binary(dockerfile) and is_binary(context_path) do
    expanded = expand_dockerfile(dockerfile, context_path)
    dockerfile_rel = relative_dockerfile(expanded, context_path)

    # The daemon only ever sees the context archive, so a Dockerfile outside
    # it could never be read — reject it here rather than let the build fail
    # with an opaque daemon error. A path that escapes upwards ("../x") and
    # one `Path.relative_to/2` could not rebase at all (an absolute path on
    # another branch of the tree) are both outside.
    if String.starts_with?(dockerfile_rel, "..") or Path.type(dockerfile_rel) === :absolute do
      {:error,
       ErrorMessage.bad_request(
         "Dockerfile is outside of the build context",
         %{dockerfile: dockerfile, context_path: context_path}
       )}
    else
      {:ok, dockerfile_rel}
    end
  end

  # A relative Dockerfile is relative to the build context, which is the only
  # place the daemon can read it from. Resolving it against the current
  # directory instead would make a build depend on where it was started, and
  # would name a file outside the context whenever the two differ.
  defp expand_dockerfile(dockerfile, context_path) do
    case Path.type(dockerfile) do
      :absolute -> dockerfile
      _relative -> Path.expand(dockerfile, context_path)
    end
  end

  defp relative_dockerfile(expanded, context_path) do
    case Path.relative_to(expanded, context_path) do
      "." -> "Dockerfile"
      rel -> rel
    end
  end

  # `name` is non-greedy so the trailing `:tag` group actually gets a
  # chance to match; with a greedy `.+` it never does. `[^/:]+` keeps a
  # registry port ("localhost:5000/app") from being read as a tag.
  @image_ref_regex ~r{^(?<name>.+?)(?::(?<tag>[^/:]+))?$}

  defp split_image_ref_tag(image_ref) when is_binary(image_ref) do
    case Regex.named_captures(@image_ref_regex, image_ref) do
      %{"name" => name, "tag" => ""} -> {name, nil}
      %{"name" => name, "tag" => tag} -> {name, tag}
      nil -> {image_ref, nil}
    end
  end

  defp build_context_tar(context_path) do
    if File.dir?(context_path) do
      args =
        case :os.type() do
          {:unix, :darwin} ->
            ["--no-xattrs", "--no-acls", "--no-mac-metadata", "-C", context_path, "-cf", "-", "."]

          _other_os ->
            ["-C", context_path, "-cf", "-", "."]
        end

      # The archive is written to stdout, so it comes back in `:stdout` as a
      # binary; `:stderr` only ever carries tar's diagnostics.
      case Exec.run(["tar" | args]) do
        {:ok, %Exec.Result{exit_status: 0, stdout: output}} ->
          {:ok, output}

        {:ok, %Exec.Result{exit_status: code, stderr: output}} ->
          {:error,
           ErrorMessage.internal_server_error(
             "Could not archive the build context: tar exited with #{inspect(code)}",
             %{exit_code: code, output: output, context_path: context_path}
           )}

        {:error, reason} ->
          {:error,
           ErrorMessage.internal_server_error(
             "Could not archive the build context: tar could not be run",
             %{reason: reason, context_path: context_path}
           )}
      end
    else
      {:error,
       ErrorMessage.bad_request(
         "The build context path is not a directory",
         %{context_path: context_path}
       )}
    end
  end

  @doc """
  Removes an image from the daemon by name or ID.

  The image must not be in use by any running container. If a container
  was created from the image but has since been stopped, pass
  `%{force: true}` in `params` to remove it anyway.

  ## Parameters

    - `image_ref` — name or ID of the image to remove. Examples:
      `"alpine:3.19"`, `"my-app:latest"`, `"sha256:abc123"`.
    - `params` — optional map. Key: `force` (boolean) to remove even if
      stopped containers were created from this image.
    - `options` — optional keyword list. See `Docker` for the options table.

  ## Returns

    - `{:ok, _}` — image removed.
    - `{:error, error}` — an `t:ErrorMessage.t/0`. `:not_found` when no
      such image exists; `:conflict` when it is in use by a container and
      `force` was not set.

  ## Examples

      {:ok, _} = Docker.Image.delete_image("alpine:3.19")

      # Force-remove even if stopped containers reference the image
      {:ok, _} = Docker.Image.delete_image("my-app:latest", %{force: true})
  """
  @spec delete_image(Docker.image_ref(), Docker.params(), Docker.options()) ::
          Docker.result(Docker.json_map() | binary() | list())
  def delete_image(image_ref, params \\ %{}, options \\ []) do
    if sandbox?(options) do
      sandbox_delete_image_response(image_ref, params, options)
    else
      do_delete_image(image_ref, params, options)
    end
  end

  defp do_delete_image(image_ref, params, options) do
    url = Util.append_query_string("/images/#{image_ref}", params)

    case Client.request(:delete, url, nil, options) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, %ErrorMessage{} = error} -> {:error, error}
    end
  end

  # ---------------------------------------------------------------------------
  # SANDBOX HELPERS
  # ---------------------------------------------------------------------------

  defp sandbox?(options) do
    sandbox_options = options[:sandbox] || []
    enabled = Keyword.get(sandbox_options, :enabled, false)
    enabled and not sandbox_disabled?()
  end

  if Code.ensure_loaded?(SandboxRegistry) do
    @doc false
    defdelegate sandbox_disabled?, to: Docker.Sandbox

    @doc false
    defdelegate sandbox_list_images_response(params, options),
      to: Docker.Sandbox,
      as: :list_images_response

    @doc false
    defdelegate sandbox_find_image_response(image_ref, options),
      to: Docker.Sandbox,
      as: :find_image_response

    @doc false
    defdelegate sandbox_pull_image_response(image, params, options),
      to: Docker.Sandbox,
      as: :pull_image_response

    @doc false
    defdelegate sandbox_build_image_response(context_path, dockerfile, tag, params, options),
      to: Docker.Sandbox,
      as: :build_image_response

    @doc false
    defdelegate sandbox_materialize_image_response(image_ref, image_or_path, params, options),
      to: Docker.Sandbox,
      as: :materialize_image_response

    @doc false
    defdelegate sandbox_delete_image_response(image_ref, params, options),
      to: Docker.Sandbox,
      as: :delete_image_response
  else
    defp sandbox_disabled?, do: true

    defp sandbox_list_images_response(params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_find_image_response(image_ref, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image_ref: #{inspect(image_ref)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_pull_image_response(image, params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image: #{inspect(image)}
      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_build_image_response(context_path, dockerfile, tag, params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      context_path: #{inspect(context_path)}
      dockerfile: #{inspect(dockerfile)}
      tag: #{inspect(tag)}
      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_materialize_image_response(image_ref, image_or_path, params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image_ref: #{inspect(image_ref)}
      image_or_path: #{inspect(image_or_path)}
      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end

    defp sandbox_delete_image_response(image_ref, params, options) do
      raise """
      Cannot use sandbox mode outside of dev/test environment.

      image_ref: #{inspect(image_ref)}
      params: #{inspect(params)}
      options: #{inspect(options)}
      """
    end
  end
end
