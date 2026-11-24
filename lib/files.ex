# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files do
  @moduledoc """
  #{"./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()}

  This module contains general functions for handling files, and also an Ecto schema which is a multimixin for storing one or more media attached to a Pointable object.

  An uploader definition must be provided for each upload, or will be automatically chosen based on the file type.

  A few definitions exist as defaults inside of this namespace, but you can also define
  your own - a `Bonfire.Files.Definition` is an extension of `Waffle.Definition`,
  however the `allowed_media_types/0` and `max_file_size/0` callback are added,
  with which you need to define what media types are accepted for these types of uploads.
  (You can also return `:all` to accept all media types).

  To use the uploader:

      iex> {:ok, media} = Bonfire.Files.upload(MyUploader, creator_or_context, %{path: "./150.png"})
      iex> media.media_type
    "image/png"
      iex> Bonfire.Files.remote_url(MyUploader, media)
    "/uploads/my/01F3AY6JV30G06BY4DR9BTW5EH"
  """

  use Needle.Mixin,
    otp_app: :bonfire_files,
    source: "bonfire_files"

  use Bonfire.Common.E
  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Bonfire.Common.Config, only: [repo: 0]
  require Needle.Changesets
  use Arrows
  import Untangle

  alias Bonfire.Files

  alias Bonfire.Files.Media

  alias Bonfire.Common.Utils
  # alias Needle.Pointer
  alias Ecto.Changeset
  alias Bonfire.Common
  alias Common.Types
  alias Common.Enums

  mixin_schema do
    belongs_to(:media, Media, primary_key: true)
  end

  @cast [:id, :media_id]
  @required [:media_id]

  @doc """
  Attempt to store a file, returning an upload, for any parent item that
  participates in the meta abstraction, providing the user/context of
  the upload.
  """
  def upload(module, creator_or_context, file, attrs \\ %{}, opts \\ [])

  def upload(module, context, "http" <> _ = url, attrs, opts) do
    # Check if this URL already exists as media to avoid duplicates
    case Bonfire.Files.Media.get_by_path(url) do
      {:ok, existing_media} ->
        # URL already exists, return existing media unless force update is requested
        if opts[:update_existing] == :force do
          upload_or_add_url(module, context, url, attrs, opts)
        else
          {:ok, existing_media}
        end

      {:error, :not_found} ->
        # URL doesn't exist, proceed
        upload_or_add_url(module, context, url, attrs, opts)
    end
  end

  def upload(module, context, files, attrs, opts)
      when is_list(files) do
    Enum.map(files, fn
      %{"href" => file} -> upload(module, context, file, attrs, opts)
      file -> upload(module, context, file, attrs, opts)
    end)
  end

  def upload(module, context, file, attrs, opts),
    do: maybe_do_upload(module, context, file, attrs, opts)

  defp upload_or_add_url(module, context, url, attrs, opts) do
    # in the test env the URL is only stored, unless `skip_fetching_remote: false` is passed to really download it
    if opts[:skip_fetching_remote] == true or
         (opts[:skip_fetching_remote] != false and Bonfire.Common.Config.env() == :test) do
      debug("Files - skip file handling and just insert url or path in DB")

      insert(
        context,
        url,
        %{size: 0, media_type: attrs[:media_type] || "remote"},
        attrs
        |> Map.put(:url, url)
      )
    else
      # the file is fetched through `Bonfire.Common.HTTP`, which refuses a private or loopback host (unless allowlisted in `:ssrf_allow_hosts`) on every hop, and caps the body size. Waffle then only ever gets a local file, and never fetches a remote URL itself.
      case download_to_tmp(url) do
        {:ok, tmp_path} ->
          try do
            maybe_do_upload(module, context, tmp_path, attrs, opts)
          after
            File.rm(tmp_path)
          end

        {:error, reason} ->
          error(reason, l("This URL cannot be fetched."))
      end
    end
  end

  @max_download_redirects 3

  # the temp file keeps the extension of the URL's path, which the stored file's extension comes from
  defp download_to_tmp(url) do
    with {:ok, body} <- fetch_body(url) do
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "bonfire_url_upload_#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}#{file_extension(url)}"
        )

      with :ok <- File.write(tmp_path, body), do: {:ok, tmp_path}
    end
  end

  @doc """
  Fetches a URL's body through `Bonfire.Common.HTTP` (every hop checked against private and loopback hosts, body size capped), following a few redirects. Also set as the `:entrepot, :uri_fetcher`, so the library's own `%URI{}` uploads are fetched the same way. Takes a URL string or a `%URI{}`.
  """
  def fetch_body(url, redirects_left \\ @max_download_redirects)

  def fetch_body(%URI{} = uri, redirects_left),
    do: fetch_body(URI.to_string(uri), redirects_left)

  def fetch_body(url, redirects_left) do
    case Bonfire.Common.HTTP.get(url) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status, headers: headers}}
      when status in [301, 302, 303, 307, 308] and redirects_left > 0 ->
        case Enum.find_value(headers, fn {k, v} -> String.downcase(k) == "location" && v end) do
          location when is_binary(location) ->
            # the next hop is requested through the same client, so it is checked again
            fetch_body(URI.merge(url, location) |> URI.to_string(), redirects_left - 1)

          _ ->
            {:error, :redirect_without_location}
        end

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  end

  defp maybe_do_upload(module, context, %{path: upload_filename}, attrs, opts)
       when is_binary(upload_filename),
       do: maybe_do_upload(module, context, upload_filename, attrs, opts)

  defp maybe_do_upload(module, context, %{filename: upload_filename}, attrs, opts)
       when is_binary(upload_filename),
       do: maybe_do_upload(module, context, upload_filename, attrs, opts)

  defp maybe_do_upload(module, context, upload_filename, attrs, opts)
       when is_binary(upload_filename) do
    opts = Utils.to_options(opts)
    debug(attrs, "uploads attrs")
    debug(upload_filename, "upload_filename")
    id = Needle.UID.generate(Bonfire.Files.Media)

    file_extension = file_extension(e(attrs, :client_name, nil) || upload_filename)

    final_filename = "#{id}#{file_extension}"

    with {:ok, tmp_path} <- maybe_move(opts[:move_original], upload_filename, final_filename),
         {:ok, file} <- init_file(module, tmp_path),
         {:ok, file_info} <- extract_metadata(file),
         :ok <- check_pixel_cap(file_info, file.path),
         module when is_atom(module) and not is_nil(module) <-
           module || definition_module(module, file_info),
         upload_source <- %Plug.Upload{
           filename: final_filename,
           path: file.path,
           content_type: Map.get(file_info, :media_type)
         },
         # TODO: fully deprecate old Waffle based upload (for now we pass through it do apply validation and transformations)
         {:ok, new_paths} <-
           module.prepare({
             upload_source,
             %{creator_id: context_id(context), file_info: file_info}
           })
           |> debug("prepared") do
      insert(
        context,
        %{file | path: Map.get(new_paths, :default)},
        # file,
        file_info
        |> Map.put(:module, module),
        # |> Enums.maybe_put(:preview, if File.exists?()),
        attrs
        |> Map.put(:id, id)
        |> Map.put(:file, new_paths)
      )
    else
      {:error, [error]} ->
        error(error)

      other ->
        error(other)
    end
  end

  # an image can declare far more pixels than its file size suggests, and the thumbnailers allocate for all of them
  defp check_pixel_cap(%{media_type: "image/" <> _}, path) do
    max_pixels = Config.get([:bonfire_files, :max_image_megapixels], 100) * 1_000_000

    case Bonfire.Files.MediaEdit.declared_pixels(path) do
      pixels when is_integer(pixels) and pixels > max_pixels ->
        {:error, l("This image has too many pixels.")}

      _ ->
        :ok
    end
  end

  defp check_pixel_cap(_file_info, _path), do: :ok

  def validate(%{file_info: %{} = file_info}, allowed_media_types, max_file_size),
    do: validate(file_info, allowed_media_types, max_file_size)

  def validate(%{media_type: media_type, size: size}, allowed_media_types, max_file_size) do
    # debug(allowed_media_types, "validate_with")
    case {allowed_media_types, max_file_size} |> debug("validate_with") do
      {_, max_file_size} when size > max_file_size ->
        {:error, file_too_large(max_file_size)}

      {:all, _} ->
        :ok

      {types, _} ->
        if Enum.member?(types, media_type) do
          :ok
        else
          {:error, file_type_not_allowed(media_type)}
        end
    end

    # |> debug("validated #{inspect media_type}?")
  end

  def validate({_file, %{file_info: %{} = file_info}}, allowed_media_types, max_file_size) do
    validate(file_info, allowed_media_types, max_file_size)
  end

  def validate({%{path: path}, _}, allowed_media_types, max_file_size) when is_binary(path) do
    extract_metadata(path)
    ~> validate(allowed_media_types, max_file_size)
  end

  def validate({path, _}, allowed_media_types, max_file_size) when is_binary(path) do
    extract_metadata(path)
    ~> validate(allowed_media_types, max_file_size)
  end

  def validate(other, _, _) do
    error(other, "File info not available so file type and/or size could not be validated")
  end

  defp file_too_large(max_file_size) do
    %Bonfire.Fail{
      code: :file_too_large,
      message: "This file exceeds the maximum upload size of #{Sizeable.filesize(max_file_size)}",
      status: 413
    }
  end

  defp file_type_not_allowed(media_type) do
    %Bonfire.Fail{
      code: :file_type_not_allowed,
      message: "Files with the format of #{media_type} are not allowed",
      status: 415
    }
  end

  defp maybe_move(true, upload_filename, final_filename) do
    new_tmp_filename =
      "#{upload_filename}_#{final_filename}"
      |> debug("new_tmp_filename")

    with :ok <- File.rename(upload_filename, new_tmp_filename) do
      {:ok, new_tmp_filename}
    else
      e ->
        error(e)
        {:ok, upload_filename}
    end
  end

  defp maybe_move(_, upload_filename, _), do: {:ok, upload_filename}

  def file_extension(path) when is_binary(path) do
    (path
     |> URI.parse()
     |> Map.get(:path) || path)
    |> Path.extname()
    |> String.downcase()
  end

  def file_extension_only(path) do
    file_extension(path) |> String.trim_leading(".")
  end

  def has_extension?(url, extensions)
      when is_binary(url) and (is_list(extensions) or is_binary(extensions)) do
    (url
     |> URI.parse()
     |> Map.get(:path) || url || "")
    |> String.ends_with?(extensions)
  end

  def has_extension?(_, _), do: false

  @doc """
  Attach a Media to an object.
  """
  def attach_media(creator, media, object) do
    repo().insert(
      files_changeset(%{id: Types.uid(object), media: media, media_id: Enums.id(media)})
    )
  end

  defp insert({creator, object} = _context, file, file_info, attrs) do
    # first insert media
    media = insert(creator, file, file_info, attrs)

    # then attach media to object
    attach_media(creator, media, object)

    media
  end

  defp insert(creator, file, file_info, attrs) do
    Media.insert(creator, file, file_info, attrs)
  end

  defp context_id({creator, _object}) do
    Types.uid(creator)
  end

  defp context_id(creator) do
    Types.uid(creator)
  end

  def definition_module(module \\ nil, file_info)

  def definition_module(fallback, %{media_type: media_type}) when not is_nil(media_type) do
    cond do
      Enum.member?(Bonfire.Files.ImageUploader.allowed_media_types(), media_type) ->
        debug(media_type, "using ImageUploader definition based on file type")
        Bonfire.Files.ImageUploader

      Enum.member?(Bonfire.Files.VideoUploader.allowed_media_types(), media_type) ->
        debug(media_type, "using VideoUploader definition based on file type")
        Bonfire.Files.VideoUploader

      true ->
        if Enum.member?(
             Bonfire.Common.Config.get_ext(
               :bonfire_files,
               # all other
               :all_allowed_media_types,
               # fallback:
               ["application/pdf"]
             ),
             media_type
           ) do
          debug(
            media_type,
            "using DocumentUploader definition based on file type"
          )

          fallback || Bonfire.Files.DocumentUploader
        else
          {:error, Bonfire.Fail.fail(:file_type_not_allowed, media_type)}
        end
    end

    # |> IO.inspect(label: "definition_module")
  end

  def definition_module(module, _file_info) do
    module
  end

  # defp insert_files(context, %Media{} = media, object) when is_binary(object) or is_map(object) do
  #   repo().insert_all(Files, conflict_target: :media) do
  # end

  defp files_changeset(pub \\ %Files{}, params) do
    # to attach media to an object
    pub
    |> Changeset.cast(params, @cast)
    |> Changeset.validate_required(@required)
    |> Changeset.assoc_constraint(:media)
    |> Changeset.unique_constraint(@cast)
  end

  @doc """
  Return the URL that a local file has.
  """

  defp url_expiration_ttl do
    # takes hours, outputs seconds
    Config.get([:bonfire_files, :url_expiration_ttl], 6) * 60 * 60
  end

  defp url_cache_ttl do
    # takes hours, outputs milliseconds
    Config.get([:bonfire_files, :url_cache_ttl], 6) * 60 * 60 * 1_000
  end

  defp maybe_rewrite_asset_host(url, host_url) when is_binary(url) and is_binary(host_url) do
    String.replace(url, Config.get([:bonfire_files, :default_asset_url], ""), host_url)
  end

  defp maybe_rewrite_asset_host(url, _), do: url

  def remote_url(module \\ nil, media, version \\ :default, opts \\ [])

  def remote_url(_module, %{file: %Entrepot.Locator{id: _} = locator}, version, opts) do
    maybe_cached_entrepot_url(locator, version, opts)
  end

  def remote_url(_module, %Entrepot.Locator{id: id} = locator, version, opts)
      when is_binary(id) do
    maybe_cached_entrepot_url(locator, version, opts)
  end

  def remote_url(module, %Media{} = media, version, _opts)
      when is_atom(module) and not is_nil(module) do
    case media.path do
      "http" <> _ = url ->
        # Handle remote media (federated content)
        # Only return URL for default version - thumbnail versions don't exist for remote content
        if version in [:default, nil], do: url, else: nil

      _ ->
        # backwards compatibility for Waffle uploads
        debug(module, "Media not stored with entrepot, fallback to delegating to")
        module.url({media.path, %{creator_id: media.creator_id}}, version)
    end
  end

  def remote_url(module, media_id, version, opts)
      when is_binary(media_id) and is_atom(module) do
    if opts[:preload_if_needed] == false do
      # Do not query for media, return error
      err(media_id, "Media data was not loaded")
      nil
    else
      case Media.one(id: media_id) do
        {:ok, media} ->
          remote_url(module, media, version, opts)

        _ ->
          warn(
            media_id,
            "Media not found"
          )

          nil
      end
    end
  end

  def remote_url(_, %Media{metadata: %{"module" => definition}} = media, version, opts) do
    case Types.maybe_to_atom(definition) do
      module when is_atom(module) and not is_nil(module) ->
        remote_url(module, media, version, opts)

      _ ->
        remote_url_fallback(media)
    end
  end

  def remote_url(_, media, _, _opts) do
    remote_url_fallback(media)
  end

  def remote_url_fallback(%{path: "http" <> _ = url}) do
    url
  end

  def remote_url_fallback(media) do
    warn(
      media,
      "remote_url called with unexpected arguments"
    )

    nil
  end

  def local_path(module \\ nil, media, version \\ :default)

  def local_path(module, %{file: %Entrepot.Locator{id: id} = locator}, version)
      when is_binary(id),
      do: entrepot_storage_apply(:path, locator, version, [])

  def local_path(_module, %Entrepot.Locator{id: id} = locator, version) when is_binary(id),
    do: entrepot_storage_apply(:path, locator, version, [])

  def local_path(module, %Media{} = media, version) when is_atom(module) and not is_nil(module),
    do: module.path({media.path, %{creator_id: media.creator_id}}, version)

  def local_path(module, media_id, version)
      when is_binary(media_id) and is_atom(module) do
    case Media.one(id: media_id) do
      {:ok, media} ->
        local_path(module, media, version)

      _ ->
        nil
    end
  end

  def local_path(_, %Media{metadata: %{"module" => definition}} = media, version) do
    case Types.maybe_to_atom(definition) do
      module when is_atom(module) and not is_nil(module) ->
        local_path(module, media, version)

      _ ->
        nil
    end
  end

  def local_path(_, _, _), do: nil

  def maybe_update_media_assoc(creator, %{files: files, media: media} = _object, changeset, attrs)
      when is_list(files) or (is_nil(files) and is_list(media)) or is_nil(media) do
    # Preload the current files association - NOTE: should actually be done in the caller of maybe_update_media_assoc before preparing the changeset
    # object = repo().preload(object, :files)

    # Get the raw attachment data from the update
    primary_image = attrs[:primary_image]
    attachments = attrs[:attachments]

    # Process the new attachments to get the expected final state
    updated_media_list =
      if primary_image || attachments do
        ap_receive_attachments(
          creator,
          primary_image,
          attachments
        )
      else
        []
      end

    # Compare current media with what should be there after the update
    current_media_ids = (media || []) |> Enums.ids() |> MapSet.new()
    new_media_ids = updated_media_list |> Enums.ids() |> MapSet.new()

    # Only update if the media has actually changed
    if not MapSet.equal?(current_media_ids, new_media_ids) do
      replace_files_assoc(changeset, updated_media_list)
    end
  end

  @doc """
  Makes `object`'s media the ones at `urls`, eg. when the site a post was imported from changed its featured image: when the URLs differ from those of its media now, `make_media` (a function with no arguments) is called for the new media, which replace all of its files. Media are compared by URL, so the same ones are kept rather than made again, and nothing is called or written when they match. Returns `{:ok, object}`.
  """
  def update_object_media(%{} = object, urls, make_media) when is_function(make_media, 0) do
    object = repo().preload(object, [files: :media], force: true)

    current = object.files |> Enum.map(& &1.media.path) |> MapSet.new()

    if current == urls |> List.wrap() |> Enums.filter_empty([]) |> MapSet.new() do
      {:ok, object}
    else
      object
      |> Ecto.Changeset.change()
      |> Bonfire.Files.Acts.AttachMedia.cast(make_media.() |> List.wrap() |> List.flatten())
      |> repo().update()
    end
  end

  defp replace_files_assoc(changeset, updated_media_list) do
    # Convert media objects to the format expected by put_assoc
    files_data =
      List.wrap(updated_media_list)
      |> Enum.uniq_by(&Enums.id/1)
      |> Enum.map(fn
        {:error, e} -> raise Bonfire.Fail, invalid_argument: e
        media -> %{media_id: Enums.id(media), media: media}
      end)

    # Use put_assoc to replace all files (this handles additions, deletions, and replacements)
    # Now works because we changed :on_replace to :delete in the schema
    changeset
    |> Ecto.Changeset.put_assoc(:files, files_data)
    |> repo().update()
  end

  @doc "Deletes the files of a media (or media id). Only the media's creator or an instance admin (as `current_user` in opts) can, unless `skip_boundary_check: true`; anything that isn't a media or its id needs `skip_boundary_check: true`."
  def delete_files(module \\ nil, media, opts \\ []) do
    opts = Bonfire.Common.Opts.to_options(opts)

    cond do
      opts[:skip_boundary_check] == true ->
        do_delete_files(module, media, opts)

      is_binary(media) ->
        with {:ok, media} <- Media.one(id: media) do
          delete_files(module, media, opts)
        end

      match?(%Media{}, media) and
          Media.may_modify?(Bonfire.Common.Utils.current_user(opts), media) ->
        do_delete_files(module, media, opts)

      true ->
        {:error, :unauthorized}
    end
  end

  defp do_delete_files(module, %{file: %Entrepot.Locator{id: id} = locator}, opts)
       when is_binary(id),
       do: entrepot_storage_apply(:delete, locator, Bonfire.Common.Opts.to_options(opts))

  defp do_delete_files(_module, %Entrepot.Locator{id: id} = locator, opts) when is_binary(id),
    do: do_delete_files(:delete, locator, opts)

  defp do_delete_files(module, %Media{} = media, _opts)
       when is_atom(module) and not is_nil(module),
       #  to support old Waffle files
       do: module.delete({media.path, media.creator_id})

  defp do_delete_files(module, media_id, opts)
       when is_binary(media_id) and is_atom(module) do
    case Media.one(id: media_id) do
      {:ok, media} ->
        do_delete_files(module, media, opts)

      _ ->
        nil
    end
  end

  defp do_delete_files(_, %Media{metadata: %{"module" => definition}} = media, opts) do
    case Types.maybe_to_atom(definition) do
      module when is_atom(module) and not is_nil(module) ->
        do_delete_files(module, media, opts)

      _ ->
        nil
    end
  end

  defp do_delete_files(_, _, _), do: nil

  def redirect_entrepot_url(path, storage \\ nil) do
    "/files/redir/#{entrepot_storage_name(storage)}/#{path}"
  end

  def cached_entrepot_storage_url(path, storage \\ nil) do
    storage =
      entrepot_storage(storage)
      |> debug("storage for #{storage}")

    cached_entrepot_url(%Entrepot.Locator{id: path, storage: storage})
  end

  def maybe_cached_entrepot_url(%Entrepot.Locator{id: _} = locator, version \\ nil, opts \\ []) do
    if opts[:permanent] || opts[:cache] == false do
      # no need to cache the redir URL
      do_entrepot_url(locator, version, opts)
    else
      cached_entrepot_url(locator, version, opts)
    end
  end

  def cached_entrepot_url(%Entrepot.Locator{id: id} = locator, version \\ nil, opts \\ []) do
    cache_key = "e_url:#{id}:#{version}"
    # debug(cache_key, "cache_key")

    Bonfire.Common.Cache.maybe_apply_cached(
      &do_entrepot_url/3,
      [locator, version, opts],
      cache_key: cache_key,
      expire: url_cache_ttl()
    )
  end

  defp do_entrepot_url(locator, version, opts \\ []) do
    entrepot_storage_apply(
      :url,
      locator,
      version,
      opts |> Keyword.put_new(:expires_in, url_expiration_ttl())
    )
    # |> debug("entrepot_url")
    ~> maybe_rewrite_asset_host(Config.get([:bonfire_files, :asset_url]))

    # |> debug("rew_url")
  end

  @entrepot_storage_map %{
    "s3" => Entrepot.Storages.S3,
    "local" => Entrepot.Storages.Disk
  }
  @default_storage "s3"
  @default_storage_module @entrepot_storage_map[@default_storage]

  defp entrepot_storage(str) when is_binary(str),
    do: Map.get(@entrepot_storage_map, str) || @default_storage_module

  defp entrepot_storage(module) when is_atom(module), do: module || @default_storage_module
  defp entrepot_storage(_), do: @default_storage_module

  defp entrepot_storage_name(module) when is_atom(module) do
    Enum.find_value(@entrepot_storage_map, fn {k, v} -> if v == module, do: k end) ||
      @default_storage
  end

  defp entrepot_storage_name(_), do: @default_storage

  defp entrepot_storage_apply(fun, locator, version \\ nil, opts)

  defp entrepot_storage_apply(fun, %{storage: storage} = locator, version, opts)
       when is_binary(storage) do
    case storage
         # backward compatibility
         |> String.replace("Capsule", "Entrepot")
         |> Types.maybe_to_module() do
      nil ->
        error(storage, "Storage module not found")

      storage ->
        entrepot_storage_apply(fun, Map.put(locator, :storage, storage), version, opts)
    end
  end

  defp entrepot_storage_apply(fun, %Entrepot.Locator{id: id, storage: storage}, version, opts)
       when (is_nil(version) or version == :default) and
              is_atom(storage) and not is_nil(storage) do
    info(storage, "storage module")

    maybe_apply_or_redirect_entrepot(storage, fun, id, opts)
  end

  defp entrepot_storage_apply(
         fun,
         %Entrepot.Locator{id: _id, storage: storage, metadata: %{} = metadata},
         version,
         opts
       )
       when is_atom(storage) and not is_nil(storage) do
    info(storage, "storage module")

    case metadata
         |> debug("metadata")
         |> Map.get(version) ||
           metadata
           |> Map.get(to_string(version)) do
      version_id when is_binary(version_id) ->
        maybe_apply_or_redirect_entrepot(storage, fun, version_id, opts)

      e ->
        debug(e, "version '#{inspect(version)}' not found")
        nil
    end
  end

  def maybe_apply_or_redirect_entrepot(storage, :url, version_or_id, opts) do
    if opts[:permanent] do
      # if we are federating or otherwise publishing or storing a URL, we use a Bonfire URL that can generate and redirect to freshly signed S3 URLs
      redirect_entrepot_url(version_or_id, storage)
    else
      Utils.maybe_apply(storage, :url, [version_or_id, opts])
    end
  end

  def maybe_apply_or_redirect_entrepot(storage, fun, version_or_id, opts) do
    Utils.maybe_apply(storage, fun, [version_or_id, opts])
  end

  defp init_file(module, file) do
    file
    |> Bonfire.Common.Enums.input_to_atoms()
    # handles downloading if remote URL
    # Waffle only reads the definition's remote file headers here; the final definition is chosen from the file's type afterwards
    |> Waffle.File.new(module || Bonfire.Files.ImageUploader)
    |> case do
      {:error, _} = e -> e
      file -> {:ok, file}
    end
  end

  def extract_metadata(path) when is_binary(path) do
    with {:ok, info} <- maybe_get_metadata(path),
         {:ok, stat} <- File.stat(path) do
      metadata =
        info
        |> Map.replace_lazy(:media_type, &Bonfire.Files.MimeTypes.normalize_type/1)
        |> Map.put(:size, stat.size)

      {:ok, metadata}
    end
  end

  def extract_metadata(%{path: path}), do: extract_metadata(path)

  defp maybe_get_metadata(path) do
    if(Code.ensure_loaded?(TwinkleStar)) do
      TwinkleStar.from_filepath(path)
    else
      %{}
    end
  end

  def data_url(content, mime_type) do
    image_base64 = Base.encode64(content)
    ["data:", mime_type, ";base64,", image_base64]
  end

  def full_url(module, media, version \\ nil, opts \\ []) do
    case remote_url(module, media, version, opts) do
      "/" <> _ = path -> Bonfire.Common.URIs.base_url() <> path
      url -> url
    end
  end

  def permanent_url(module, media, version \\ nil, opts \\ []) do
    full_url(module, media, version, Keyword.put(opts, :permanent, true))
  end

  @doc "The URL that places `media` in a body (see `Bonfire.Files.InlineMedia`): for an upload, its `permanent_url/4`, the same URL its `attachment` federates with; for remote media or a link, its own URL."
  def inline_url(%{media: %Media{} = media}), do: inline_url(media)
  def inline_url(%Media{path: "http" <> _ = url}), do: url
  def inline_url(%Media{} = media), do: permanent_url(nil, media)
  def inline_url(_), do: nil

  # TODO: a `PrimaryMedia` mixin pointing at an object's main image (as `Bonfire.Geolocate.PrimaryGeolocation` does for its place), instead of a flag in each file's metadata and this split at render time
  def split_primary_image(files) when is_list(files) do
    case files
         |> Enum.sort_by(&Enums.id/1, :desc)
         |> Enum.split_with(&is_primary_image?/1) do
      {[primary | more_primaries], others} -> {primary, more_primaries ++ others}
      {[], others} -> {nil, others}
    end
  end

  def split_primary_image(file) when is_map(file) do
    # Handle single file case
    if is_primary_image?(file) do
      {file, []}
    else
      {nil, [file]}
    end
  end

  def split_primary_image(_), do: {nil, []}

  @doc "Like `split_primary_image/1`, but when none is flagged as the primary image (as the banner of a remote event, sent as an attachment), the first image is the one."
  def split_cover_image(files) do
    case split_primary_image(files) do
      {nil, others} ->
        case Enum.find(List.wrap(files), &image_file?/1) do
          nil -> {nil, others}
          cover -> {cover, Enum.reject(others, &(&1 == cover))}
        end

      split ->
        split
    end
  end

  defp image_file?(file), do: match?("image" <> _, get_media_type(file))

  defp is_primary_image?(%{media: %{metadata: %{"primary_image" => true_val}}})
       when true_val in [true, "true"],
       do: true

  defp is_primary_image?(%{metadata: %{"primary_image" => true_val}})
       when true_val in [true, "true"],
       do: true

  defp is_primary_image?(_), do: false

  def split_media_by_type(files) when is_list(files) do
    files
    |> Enum.sort_by(&Enums.id/1, :desc)
    |> Enum.reduce(%{primary_image: nil, images: [], links: []}, fn file, acc ->
      cond do
        is_primary_image?(file) ->
          %{acc | primary_image: file}

        is_publishable_media?(file) ->
          %{acc | images: [file | acc.images]}

        is_remote_link?(file) ->
          %{acc | links: [file | acc.links]}

        true ->
          # Skip files that don't match any criteria
          acc
      end
    end)
    |> Map.update!(:images, &Enum.reverse/1)
    |> Map.update!(:links, &Enum.reverse/1)
  end

  def split_media_by_type(file) when is_map(file) do
    cond do
      is_primary_image?(file) ->
        %{primary_image: file, images: [], links: []}

      is_publishable_media?(file) ->
        %{primary_image: nil, images: [file], links: []}

      is_remote_link?(file) ->
        %{primary_image: nil, images: [], links: [file]}

      true ->
        %{primary_image: nil, images: [], links: []}
    end
  end

  def split_media_by_type(_), do: %{primary_image: nil, images: [], links: []}

  # Helper to get media_type from nested structure
  defp get_media_type(%{media: %{media_type: media_type}}), do: media_type
  defp get_media_type(%{media_type: media_type}), do: media_type
  defp get_media_type(_), do: nil

  # Helper to get path from nested structure
  defp get_path(%{media: %{path: path}}), do: path
  defp get_path(%{path: path}), do: path
  defp get_path(_), do: nil

  # Match the same logic as ap_publish_activity - include images, audio, video, and non-HTTP documents
  defp is_publishable_media?(file) do
    media_type = get_media_type(file)

    case {media_type, get_path(file)} do
      # Exclude remote HTTP links
      {_, "http" <> _} -> false
      # Include media types that match ap_publish_activity logic
      {"image" <> _, _} -> true
      {"audio" <> _, _} -> true
      {"video" <> _, _} -> true
      # {media_type, _} when is_binary(media_type) -> true
      _ -> false
    end
  end

  # Separate function for remote links
  defp is_remote_link?(file) do
    case {get_path(file), get_media_type(file)} do
      {"http" <> _, _} -> true
      {_, "remote"} -> true
      _ -> false
    end
  end

  ###

  @doc """
  Add an object's media to the AS2 object being prepared for it: the primary image as `image`, and the rest as `attachment` (the media we host first, then the link previews we resolved).

  Appends to `attachment` rather than replacing it, so an object type that puts its own attachments there keeps them.

  Given the `:audience` the object is addressed to (the group's id, from `AdapterUtils.determine_recipients/4`), it also makes a titled thread starter in that group a `Page`, since the types `Page`, `Article` and `Video` are what Mbin files as a thread, where a `Note` becomes a microblog post whatever its `name`. That is the outgoing side of how `Bonfire.Files.Media` takes an incoming `Page` in. Replies, untitled objects and objects with no `:audience` keep their type.
  """
  def ap_merge_media(object, media, opts \\ []) do
    %{primary_image: primary_image, images: images, links: links} = split_media_by_type(media)

    object
    |> Enums.maybe_put("image", ap_publish_activity(primary_image))
    |> Enums.maybe_put(
      "attachment",
      (List.wrap(object["attachment"]) ++ ap_publish_activity(images) ++ ap_publish_link(links))
      |> Enums.filter_empty(nil)
    )
    |> ap_thread_starter_as_page(opts[:audience])
  end

  defp ap_thread_starter_as_page(object, audience) do
    if not is_nil(audience) and object["name"] not in [nil, ""] and is_nil(object["inReplyTo"]),
      do: Map.put(object, "type", "Page"),
      else: object
  end

  # NOTE: AS2 gives an attachment a single `name`, which Mastodon & co. read as the image description, so `Media.media_alt/1` puts the author's alt text there, falling back to the label (a caption, or the original filename) for media that never got alt text.
  def ap_publish_activity(medias) when is_list(medias) do
    Enum.map(medias, &ap_publish_activity/1)
    |> Enums.filter_empty([])
  end

  def ap_publish_activity(%Media{media_type: "image" <> _} = media) do
    %{
      "type" => "Image",
      "mediaType" => media.media_type,
      "url" => permanent_url(Bonfire.Files.ImageUploader, media),
      "name" => Media.media_alt(media),
      "blurhash" => Bonfire.Files.Blurred.blurhash_cached(media)
    }

    # |> debug()
  end

  def ap_publish_activity(%Media{media_type: "audio" <> _} = media) do
    %{
      "type" => "Audio",
      "mediaType" => media.media_type,
      "url" => permanent_url(Bonfire.Files.DocumentUploader, media),
      "name" => Media.media_alt(media)
    }
  end

  def ap_publish_activity(%Media{media_type: "video" <> _} = media) do
    %{
      "type" => "Video",
      "mediaType" => media.media_type,
      "url" => permanent_url(Bonfire.Files.DocumentUploader, media),
      "name" => Media.media_alt(media)
    }
  end

  def ap_publish_activity(%Media{path: "http" <> _} = media) do
    #  skip remote links/docs
    nil
  end

  def ap_publish_activity(%Media{} = media) do
    %{
      "type" => "Document",
      "mediaType" => media.media_type,
      "url" => permanent_url(Bonfire.Files.DocumentUploader, media),
      "name" => Media.media_alt(media)
    }
  end

  def ap_publish_activity(other) do
    debug(other, "Skip unrecognised media")
    nil
  end

  @doc """
  Prepare a link-preview `Media` (one that points at a remote URL rather than an uploaded file) as an AS2 `Link` attachment, as FEP-8967 has it: the `Link` carries its `href` and its title as `name` (as AS2's own `Link` does), and what we resolved for the link (title, description, cover image, author, and `type`, which says whether the page plays: `Video`, `Audio` or `Page`) goes in its `preview`.

  These are skipped by `ap_publish_activity/1`, which only handles media we host.
  """
  def ap_publish_link(medias) when is_list(medias) do
    Enum.map(medias, &ap_publish_link/1)
    |> Enums.filter_empty([])
  end

  def ap_publish_link(%Media{} = media) do
    case Common.Media.media_url(media) do
      "http" <> _ = url ->
        %{
          "type" => "Link",
          "mediaType" => media.media_type,
          "href" => url,
          "name" => Media.media_label(media),
          "preview" => ap_link_preview(media)
        }
        |> Enums.filter_empty(%{})

      other ->
        debug(other, "Skip link with no remote URL")
        nil
    end
  end

  def ap_publish_link(other) do
    debug(other, "Skip unrecognised link")
    nil
  end

  # a link's FEP-8967 `preview`: its `type` is `Video` or `Audio` when the page plays, so a receiver fetches the player from the provider, else `Page`
  defp ap_link_preview(%Media{metadata: metadata} = media) do
    %{
      "type" => Media.player_type(media) || "Page",
      "name" => Media.media_label(media),
      "summary" => Media.description(media),
      "image" => ap_image_object(Media.preview_image_url(media)),
      "attributedTo" =>
        %{
          "name" => e(metadata, "oembed", "author_name", nil),
          "url" =>
            case e(metadata, "oembed", "author_url", nil) do
              "http" <> _ = author_url -> %{"href" => author_url}
              _ -> nil
            end
        }
        |> Enums.filter_empty(nil)
    }
    |> Enums.filter_empty(nil)
  end

  @doc "Wrap a cover image URL as an AS2 `Image`, so a receiver has something to render without fetching the origin."
  def ap_image_object(url) when is_binary(url) and url != "" do
    %{"type" => "Image", "url" => url}
  end

  def ap_image_object(_), do: nil

  def ap_transform_url(urls, target_host, target_actor_ids) when is_list(urls) do
    Enum.map(urls, &ap_transform_url(&1, target_host, target_actor_ids))
  end

  def ap_transform_url(attachment, target_host, [target_actor_id]) do
    ap_transform_url(attachment, target_host, target_actor_id)
  end

  def ap_transform_url(attachment, target_host, more_than_one) when is_list(more_than_one) do
    ap_transform_url(attachment, target_host, nil)
  end

  def ap_transform_url(attachment, target_host, target_actor_id)
      when is_binary(target_actor_id) or is_binary(target_host) do
    rewrite = fn url ->
      target = Base.url_encode64(target_actor_id || target_host)
      String.replace(url, "/files/redir/", "/files/redir/f/#{target}/")
    end

    cond do
      is_map(attachment) and is_binary(attachment["href"]) ->
        %{attachment | "href" => rewrite.(attachment["href"])}

      is_map(attachment) and is_binary(attachment["url"]) ->
        %{attachment | "url" => rewrite.(attachment["url"])}

      is_binary(attachment) ->
        rewrite.(attachment)

      true ->
        attachment
    end
  end

  # no target host or actor ID to encode, return attachment unchanged
  def ap_transform_url(attachment, _target_host, _target_actor_id), do: attachment

  @doc "Create or retrieve a Media record for a remote URL without downloading the file. Anything but an `http(s)` URL is refused, since `upload/5` would read it as a path on this server, and this is what remote data (an incoming object's attachments, a remote actor's icon) goes through."
  def save_url_as_media(creator, url, attrs \\ %{}, module \\ nil) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        module = module || definition_module(nil, attrs)

        upload(module, creator, url, Map.put_new(attrs, :client_name, url),
          skip_fetching_remote: true
        )

      _ ->
        warn(url, "Not a remote URL, refusing to read it as a local file")
        {:error, :not_a_remote_url}
    end
  end

  @doc """
  The Media for an incoming AS2 object: its `attachment`s, with its `image`/`icon` as the primary image.

  A `Video` also gets its own id unfurled. Peertube may carry nothing playable or embeddable in its AS2 (it depends on the encoding status), so the player details have to be discovered from the page rather than trusted from the attachments, which is what `Media.maybe_fetch_and_save/3` does and `ap_receive_attachments/3` deliberately does not.
  """
  def ap_receive_media(creator, %{} = object) do
    attachments =
      ap_receive_attachments(
        creator,
        e(object, "image", nil) || e(object, "icon", nil),
        List.wrap(e(object, "attachment", []))
      )
      |> List.wrap()

    attachments ++ video_oembed(creator, object)
  end

  def ap_receive_media(_creator, _object), do: []

  defp video_oembed(creator, object) do
    if "Video" in List.wrap(e(object, "type", nil)) do
      Media.maybe_fetch_and_save(creator, e(object, "id", nil))
      |> List.wrap()
    else
      []
    end
  end

  def ap_receive_attachments(creator, primary_image, attachments)
      when is_binary(primary_image) or is_map(primary_image) do
    attachments = List.wrap(attachments)

    if Enum.any?(attachments, &link_attachment?/1) do
      # a thumbnail sent beside a link is that link's preview, not a picture of its own: Lemmy sends a link post's that way. Kept as the FEP-8967 `preview.image`, which a card shows when our own unfurl finds no image
      attachments
      |> Enum.map(&maybe_put_link_preview_image(&1, primary_image))
      |> then(&ap_receive_attachments(creator, false, &1))
    else
      [
        ap_receive_attachments(creator, true, primary_image),
        ap_receive_attachments(creator, false, attachments)
      ]
      |> List.flatten()
      |> Enums.filter_empty([])
    end
  end

  def ap_receive_attachments(creator, primary_image?, attachments) when is_list(attachments),
    do:
      attachments
      |> Enum.map(&ap_receive_attachments(creator, primary_image?, &1))
      |> List.flatten()
      |> Enums.filter_empty([])

  def ap_receive_attachments(
        %{character: %{peered: %{canonical_uri: actor_url}}} = creator,
        _primary_image?,
        %{"name" => "Live stream preview", "url" => _gif_url} = attachment
      ) do
    # special case for owncast stream
    # TODO: a better way?
    Bonfire.Files.Media.maybe_fetch_and_save(creator, actor_url)
  end

  def ap_receive_attachments(creator, primary_image?, %{"url" => urls} = attachment)
      when is_list(urls) do
    attachment = Map.drop(attachment, ["url"])

    urls
    |> Enum.map(fn
      %{} = url ->
        ap_receive_attachments(creator, primary_image?, merge_attachment_url(attachment, url))

      url when is_binary(url) ->
        ap_receive_attachments(creator, primary_image?, Map.merge(attachment, %{"href" => url}))

      other ->
        error(other, "unexpected url data")
        nil
    end)
    |> List.flatten()
    |> Enums.filter_empty([])
  end

  def ap_receive_attachments(creator, primary_image?, %{"url" => %{} = url} = attachment) do
    ap_receive_attachments(
      creator,
      primary_image?,
      Map.drop(attachment, ["url"]) |> merge_attachment_url(url)
    )
  end

  # An attachment's `url` is itself an AS2 `Link` object, so folding it in must not let its `"type" => "Link"` stand in for the attachment's own type — that would turn every `Document`/`Image` into a link and route it to the wrong uploader.
  defp merge_attachment_url(attachment, %{} = url) do
    Map.merge(url, attachment)
  end

  def ap_receive_attachments(creator, primary_image?, url) when is_binary(url) do
    ap_receive_attachments(creator, primary_image?, %{"href" => url})
  end

  def ap_receive_attachments(creator, primary_image?, %{} = attachment) do
    # debug(creator)
    debug(attachment, "handle attachment")

    url = e(attachment, "href", nil) || e(attachment, "url", nil)
    type = attachment["mediaType"] || attachment["type"]

    module =
      if(attachment["type"] == "Link",
        do: Bonfire.Files.DocumentUploader,
        else: definition_module(%{media_type: type})
      )

    metadata = ap_attachment_metadata(attachment, primary_image?)

    with nil <- maybe_unfurl_link_attachment(creator, url, attachment, metadata),
         module when is_atom(module) and not is_nil(module) <- module,
         {:ok, uploaded} <-
           save_url_as_media(
             creator,
             url,
             %{
               media_type: type,
               client_name: url,
               metadata: metadata
             },
             module
           )
           |> debug("added attachment") do
      uploaded
    else
      %Media{} = unfurled ->
        unfurled

      list when is_list(list) ->
        list
        |> Enum.map(fn
          {:ok, uploaded} ->
            uploaded

          _e ->
            warn("Could not upload one of the files")
            nil
        end)

      e ->
        error(e, "Could not upload file")
        debug(url)
        nil
    end
  end

  def ap_receive_attachments(_creator, _, nil) do
    nil
  end

  @doc """
  Media for an AS2 attachment whose file we already hold, such as a picture inside an account archive: `path` is stored on our server, and the attachment gives what a remote one would (alt text, media type).

  The path must come from the importer's own staged dir, never from remote data: `upload/5` reads whatever path it's given from our disk, which is why `ap_receive_attachments/3` refuses anything but an `http(s)` URL.
  """
  def ap_receive_local_attachment(creator_or_context, path, %{} = attachment)
      when is_binary(path) do
    type = attachment["mediaType"] || attachment["type"]

    case definition_module(%{media_type: type}) do
      module when is_atom(module) and not is_nil(module) ->
        upload(module, creator_or_context, path, %{
          media_type: type,
          client_name: Path.basename(path),
          metadata: ap_attachment_metadata(attachment, false)
        })

      other ->
        error(other, "No uploader for this attachment's media type")
    end
  end

  # what an attachment says about its file, kept on the Media whether the file is remote or one we hold
  defp ap_attachment_metadata(attachment, primary_image?) do
    attachment
    |> Map.drop(["name", "summary", "type", "mediaType", "href", "url"])
    |> ap_attachment_name(attachment)
    |> Enums.maybe_put(:primary_image, primary_image?)
    |> Enums.maybe_put(:source_type, "activitypub")

    #  |> Enums.maybe_put(:duration, attachment["duration"])
    #  |> Enums.maybe_put(:width, attachment["width"])
    #  |> Enums.maybe_put(:height, attachment["height"])
    #  |> Enums.maybe_put(:blurhash, attachment["blurhash"])
  end

  def ap_receive_attachments(_creator, _, attachment) do
    error(attachment, "Dunno how to handle this")
    nil
  end

  @doc "Whether an AS2 attachment is a link, which FEP-8967 says to show as an attached link card rather than a file."
  def link_attachment?(%{"type" => "Link"}), do: true
  def link_attachment?(_), do: false

  @doc "Whether a link attachment came with text of its own: a `name`, or a FEP-8967 `preview` with a `name` or `summary`. A link that has text is shown with it rather than unfurled. A `name` that is only a URL is not text of its own (Gancio names an online event's link with the link itself)."
  def link_text?(attachment) do
    Enum.any?(
      [
        link_name(attachment),
        e(attachment, "preview", "name", nil),
        e(attachment, "preview", "summary", nil)
      ],
      &(is_binary(&1) and String.trim(&1) != "")
    )
  end

  # a link's `name`, unless it is only a URL, which is no title
  defp link_name(attachment) do
    case e(attachment, "name", nil) do
      name when is_binary(name) -> if not Bonfire.Common.URIs.url_only?(name), do: name
      _ -> nil
    end
  end

  # the `name` of a link's FEP-8967 `preview`, unless it is only a URL
  defp link_preview_name(attachment) do
    case e(attachment, "preview", "name", nil) do
      name when is_binary(name) -> if not Bonfire.Common.URIs.url_only?(name), do: name
      _ -> nil
    end
  end

  defp maybe_put_link_preview_image(%{"type" => "Link"} = attachment, image) do
    Map.update(attachment, "preview", %{"image" => image}, fn
      %{} = preview -> Map.put_new(preview, "image", image)
      other -> other
    end)
  end

  defp maybe_put_link_preview_image(attachment, _image), do: attachment

  # a link that came with no text, or whose FEP-8967 `preview` says it plays (`Video` or `Audio`), gets our own preview, so a player comes from its provider and never from what was sent; what was sent (eg. the thumbnail in `preview`) is kept under it as the fallback. Returns nil when there's nothing to unfurl or the unfurl found nothing, so the caller saves the bare link instead
  defp maybe_unfurl_link_attachment(creator, url, %{"type" => "Link"} = attachment, metadata)
       when is_binary(url) do
    if not link_text?(attachment) or e(attachment, "preview", "type", nil) in ["Video", "Audio"] do
      case Media.maybe_fetch_and_save(creator, url, extra: metadata) do
        %Media{} = media -> media
        _ -> nil
      end
    end
  end

  defp maybe_unfurl_link_attachment(_creator, _url, _attachment, _metadata), do: nil

  # AS2 gives an attachment one `name`, but it means different things by type: on a `Link` (a link preview) it titles the linked page, while on media it describes what the media shows, which is what Mastodon & co. put in their alt text field. Keeping the two apart is what makes remote alt text usable as alt text.
  defp ap_attachment_name(metadata, %{"type" => "Link"} = attachment) do
    metadata
    # not a URL-only name: the label is read before the unfurled title, so it would hide it. A FEP-8967 `preview` has the card's title, description and image, and wins; the `Link`'s own `name`, `summary` and `image` (what AS2's `Link` and older senders have) are the fallback
    |> Enums.maybe_put("label", link_preview_name(attachment) || link_name(attachment))
    |> Enums.maybe_put(
      "description",
      e(attachment, "preview", "summary", nil) || attachment["summary"]
    )
    |> Enums.maybe_put("image", e(attachment, "preview", "image", nil) || attachment["image"])
  end

  defp ap_attachment_name(metadata, attachment) do
    Enums.maybe_put(metadata, "alt", attachment["name"])
  end

  def normalise_size(size, default \\ 8)

  def normalise_size(none, default) when is_nil(none) or none == 0 do
    normalise_size(default, 8)
  end

  def normalise_size(size, default) when is_number(size) do
    size * 1_000_000
  end

  def normalise_size(size, default) do
    Types.maybe_to_float(size, default)
    |> normalise_size(default)
  end

  def link_type(url, meta) do
    if is_research?(url, meta) do
      "research"
    else
      e(meta, :facebook, "type", nil) || e(meta, :oembed, "type", nil) ||
        e(meta, :wikidata, "itemType", nil) || "link"
    end
  end

  def is_research?(url, meta) do
    # Check JSON-LD (handle both single object and array)
    # Otherwise delegate to relevant extension if available
    e(meta, "oembed", "DOI", nil) ||
      e(meta, "other", "citation_doi", nil) ||
      check_json_ld_type(e(meta, "json_ld", nil), [
        "ScholarlyArticle",
        "Dataset",
        "https://schema.org/ScholarlyArticle",
        "https://schema.org/Dataset"
      ]) ||
      Utils.maybe_apply(Bonfire.OpenScience, :is_research?, [url, meta], fallback_return: false)
  end

  defp check_json_ld_type(json_ld, find_in) when is_list(json_ld) do
    Enum.any?(json_ld, fn item ->
      check_json_ld_type(item, find_in)
    end)
  end

  defp check_json_ld_type(json_ld, find_in) when is_map(json_ld) do
    e(json_ld, "@type", nil) in find_in
  end

  defp check_json_ld_type(_, _), do: false
end
