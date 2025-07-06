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
  import Bonfire.Common.Config, only: [repo: 0]
  require Needle.Changesets
  use Arrows
  import Untangle

  alias Bonfire.Files

  alias Bonfire.Files.Media
  alias Bonfire.Files.FileDenied

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
    if opts[:skip_fetching_remote] == true or
         Bonfire.Common.Config.env() == :test do
      debug("Files - skip file handling and just insert url or path in DB")

      insert(
        context,
        url,
        %{size: 0, media_type: attrs[:media_type] || "remote"},
        attrs
        |> Map.put(:url, url)
      )
    else
      maybe_do_upload(module, context, url, attrs, opts)
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
         module when is_atom(module) and not is_nil(module) <-
           definition_module(module, file_info),
         #  :ok <- module.validate(file_info), # note: already called by Waffle
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

  def validate(%{file_info: %{} = file_info}, allowed_media_types, max_file_size),
    do: validate(file_info, allowed_media_types, max_file_size)

  def validate(%{media_type: media_type, size: size}, allowed_media_types, max_file_size) do
    case {allowed_media_types, max_file_size} |> debug("validate_with") do
      {_, max_file_size} when size > max_file_size ->
        {:error, FileDenied.new(max_file_size)}

      {:all, _} ->
        :ok

      {types, _} ->
        if Enum.member?(types, media_type) do
          :ok
        else
          {:error, FileDenied.new(media_type)}
        end
    end
    |> debug("validated?")
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

  defp insert({creator, object}, file, file_info, attrs) do
    # to attach media to an object
    media = insert(creator, file, file_info, attrs)

    repo().insert(
      files_changeset(%{id: Types.uid(object), media: media, media_id: Enums.id(media)})
    )

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

  defp definition_module(module \\ nil, file_info)

  defp definition_module(nil, %{media_type: media_type}) do
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
               # fallback
               ["application/pdf"]
             ),
             media_type
           ) do
          debug(
            media_type,
            "using DocumentUploader definition based on file type"
          )

          Bonfire.Files.DocumentUploader
        else
          {:error, FileDenied.new(media_type)}
        end
    end

    # |> IO.inspect(label: "definition_module")
  end

  defp definition_module(module, _file_info) do
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
        # Handle remote media (federated content) - return the original HTTP URL
        url

      _ ->
        # backwards compatibility for Waffle uploads
        debug(module, "Media not stored with entrepot, fallback to delegating to")
        module.url({media.path, %{creator_id: media.creator_id}}, version)
    end
  end

  def remote_url(module, media_id, version, opts)
      when is_binary(media_id) and is_atom(module) do
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

  defp replace_files_assoc(changeset, updated_media_list) do
    # Convert media objects to the format expected by put_assoc
    files_data =
      List.wrap(updated_media_list)
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

  def delete_files(module \\ nil, media, opts \\ [])

  def delete_files(module, %{file: %Entrepot.Locator{id: id} = locator}, opts)
      when is_binary(id),
      do: entrepot_storage_apply(:delete, locator, opts)

  def delete_files(_module, %Entrepot.Locator{id: id} = locator, opts) when is_binary(id),
    do: delete_files(:delete, locator, opts)

  def delete_files(module, %Media{} = media, _opts) when is_atom(module) and not is_nil(module),
    #  to support old Waffle files
    do: module.delete({media.path, media.creator_id})

  def delete_files(module, media_id, opts)
      when is_binary(media_id) and is_atom(module) do
    case Media.one(id: media_id) do
      {:ok, media} ->
        delete_files(module, media, opts)

      _ ->
        nil
    end
  end

  def delete_files(_, %Media{metadata: %{"module" => definition}} = media, opts) do
    case Types.maybe_to_atom(definition) do
      module when is_atom(module) and not is_nil(module) ->
        delete_files(module, media, opts)

      _ ->
        nil
    end
  end

  def delete_files(_, _, _), do: nil

  def redirect_entrepot_url(path, storage \\ nil) do
    "/files/redir/#{entrepot_storage_name(storage)}/#{path}"
  end

  def cached_entrepot_storage_url(path, storage \\ nil) do
    storage =
      entrepot_storage(storage)
      |> debug("storage")

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
    |> Waffle.File.new(module)
    |> case do
      {:error, _} = e -> e
      file -> {:ok, file}
    end
  end

  def extract_metadata(path) when is_binary(path) do
    with {:ok, info} <- maybe_get_metadata(path),
         {:ok, stat} <- File.stat(path) do
      {:ok, Map.put(info, :size, stat.size)}
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

  def permanent_url(module, media, version \\ nil) do
    full_url(module, media, version, permanent: true)
  end

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

  defp is_primary_image?(%{media: %{metadata: %{"primary_image" => true_val}}})
       when true_val in [true, "true"],
       do: true

  defp is_primary_image?(%{metadata: %{"primary_image" => true_val}})
       when true_val in [true, "true"],
       do: true

  defp is_primary_image?(_), do: false

  ### 

  def ap_publish_activity(medias) when is_list(medias) do
    Enum.map(medias, &ap_publish_activity/1)
    |> Enums.filter_empty([])
  end

  def ap_publish_activity(%Media{media_type: "image" <> _} = media) do
    %{
      "type" => "Image",
      "mediaType" => media.media_type,
      "url" => permanent_url(Bonfire.Files.ImageUploader, media),
      "name" => media.metadata["label"],
      "blurhash" => Bonfire.Files.Blurred.blurhash_cached(media)
    }

    # |> debug()
  end

  def ap_publish_activity(%Media{media_type: "audio" <> _} = media) do
    %{
      "type" => "Audio",
      "mediaType" => media.media_type,
      "url" => permanent_url(Bonfire.Files.DocumentUploader, media),
      "name" => media.metadata["label"]
    }
  end

  def ap_publish_activity(%Media{media_type: "video" <> _} = media) do
    %{
      "type" => "Video",
      "mediaType" => media.media_type,
      "url" => permanent_url(Bonfire.Files.DocumentUploader, media),
      "name" => media.metadata["label"]
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
      "name" => media.metadata["label"]
    }
  end

  def ap_publish_activity(other) do
    debug(other, "Skip unrecognised media")
    nil
  end

  def ap_transform_url(urls, target_host, target_actor_id) when is_list(urls) do
    Enum.map(urls, &ap_transform_url(&1, target_host, target_actor_id))
  end

  def ap_transform_url(attachment, target_host, target_actor_id) do
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

  def ap_receive_attachments(creator, primary_image, attachments)
      when is_binary(primary_image) or is_map(primary_image) or is_list(primary_image) do
    [
      ap_receive_attachments(creator, true, primary_image),
      ap_receive_attachments(creator, false, attachments)
    ]
    |> List.flatten()
    |> Enums.filter_empty([])
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
    Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(creator, actor_url)
  end

  def ap_receive_attachments(creator, primary_image?, %{"url" => urls} = attachment)
      when is_list(urls) do
    attachment = Map.drop(attachment, ["url"])

    urls
    |> Enum.map(fn
      %{} = url ->
        ap_receive_attachments(creator, primary_image?, Map.merge(attachment, url))

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
      Map.drop(attachment, ["url"]) |> Map.merge(url)
    )
  end

  def ap_receive_attachments(creator, primary_image?, url) when is_binary(url) do
    ap_receive_attachments(creator, primary_image?, %{"href" => url})
  end

  def ap_receive_attachments(creator, primary_image?, %{} = attachment) do
    # debug(creator)
    debug(attachment, "handle attachment")

    url = e(attachment, "href", nil) || e(attachment, "url", nil)
    type = attachment["mediaType"] || attachment["type"]

    with {:ok, uploaded} <-
           upload(
             definition_module(%{media_type: type}),
             creator,
             url,
             %{
               media_type: type,
               client_name: url,
               metadata:
                 %{}
                 |> Enums.maybe_put(:label, attachment["name"])
                 |> Enums.maybe_put(:blurhash, attachment["blurhash"])
                 |> Enums.maybe_put(:primary_image, primary_image?)
             },
             skip_fetching_remote: true
           )
           |> debug("uploaded") do
      uploaded
    else
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

  def ap_receive_attachments(_creator, _, attachment) do
    error(attachment, "Dunno how to handle this")
    nil
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
    if is_research(url, meta) do
      "research"
    else
      e(meta, :facebook, "type", nil) || e(meta, :oembed, "type", nil) ||
        e(meta, :wikidata, "itemType", nil) || "link"
    end
  end

  def is_research(url, meta) do
    (e(meta, "wikibase", "itemType", nil) in ["journalArticle"] or
       e(meta, "wikibase", "identifiers", "doi", nil)) ||
      e(meta, "crossref", "DOI", nil) || e(meta, "oembed", "DOI", nil) ||
      e(meta, "other", "prism.doi", nil) ||
      e(meta, "other", "citation_doi", nil) || e(meta, "other", "citation_doi", nil) ||
      ed(meta, "json_ld", "@type", nil) in ["ScholarlyArticle", "Dataset"] ||
      String.starts_with?(url || "", "https://doi.org/")
  end
end
