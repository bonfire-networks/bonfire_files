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

  def upload(module, context, files, attrs, opts)
      when is_list(files) do
    Enum.map(files, fn
      %{"href" => file} -> upload(module, context, file, attrs, opts)
      file -> upload(module, context, file, attrs, opts)
    end)
  end

  def upload(module, context, file, attrs, opts),
    do: maybe_do_upload(module, context, file, attrs, opts)

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
    path
    |> URI.parse()
    |> Map.get(:path, path)
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
  # 6 hours in seconds
  @url_expiration_ttl 60 * 60 * 6
  # 10 minutes in ms less to allow for cache expiry
  @url_cache_ttl (@url_expiration_ttl - 60 * 10) * 1_000

  def remote_url(module \\ nil, media, version \\ :default)

  def remote_url(_module, %{file: %Entrepot.Locator{id: id} = locator}, version)
      when is_binary(id) do
    Bonfire.Common.Cache.maybe_apply_cached(
      &entrepot_storage_apply/4,
      [:url, locator, version, [expires_in: @url_expiration_ttl]],
      expire: @url_cache_ttl
    )
    |> Utils.ok_unwrap()
  end

  def remote_url(_module, %Entrepot.Locator{id: id} = locator, version) when is_binary(id) do
    Bonfire.Common.Cache.maybe_apply_cached(
      &entrepot_storage_apply/4,
      [:url, locator, version, [expires_in: @url_expiration_ttl]],
      expire: @url_cache_ttl
    )
    |> Utils.ok_unwrap()
  end

  def remote_url(module, %Media{} = media, version) when is_atom(module) and not is_nil(module) do
    info(module, "remote_url module")
    module.url({media.path, %{creator_id: media.creator_id}}, version)
  end

  def remote_url(module, media_id, version)
      when is_binary(media_id) and is_atom(module) do
    case Media.one(id: media_id) do
      {:ok, media} ->
        remote_url(module, media, version)

      _ ->
        nil
    end
  end

  def remote_url(_, %Media{metadata: %{"module" => definition}} = media, version) do
    case Types.maybe_to_atom(definition) do
      module when is_atom(module) and not is_nil(module) ->
        remote_url(module, media, version)

      _ ->
        nil
    end
  end

  def remote_url(_, media, _) do
    debug(
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

  defp entrepot_storage_apply(fun, locator, version \\ nil, opts)

  defp entrepot_storage_apply(fun, %{storage: storage} = locator, version, opts)
       when is_binary(storage) do
    case storage
         # temporary
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

    Utils.maybe_apply(storage, fun, [id, opts])
  end

  defp entrepot_storage_apply(
         fun,
         %Entrepot.Locator{id: id, storage: storage, metadata: %{} = metadata},
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
        Utils.maybe_apply(storage, fun, [version_id, opts])

      e ->
        debug(e, "version '#{inspect(version)}' not found")
        nil
    end
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

  def full_url(module, media, version \\ nil) do
    case remote_url(module, media, version) do
      "/" <> _ = path -> Bonfire.Common.URIs.base_url() <> path
      url -> url
    end
  end

  def ap_publish_activity(medias) when is_list(medias) do
    Enum.map(medias, &ap_publish_activity/1)
    |> Enums.filter_empty([])
  end

  def ap_publish_activity(%Media{media_type: "image" <> _} = media) do
    %{
      "type" => "Image",
      "mediaType" => media.media_type,
      "url" => full_url(Bonfire.Files.ImageUploader, media),
      "name" => media.metadata["label"],
      "blurhash" => Bonfire.Files.Blurred.blurhash_cached(media)
    }

    # |> debug()
  end

  def ap_publish_activity(%Media{media_type: "audio" <> _} = media) do
    %{
      "type" => "Audio",
      "mediaType" => media.media_type,
      "url" => full_url(Bonfire.Files.DocumentUploader, media),
      "name" => media.metadata["label"]
    }
  end

  def ap_publish_activity(%Media{media_type: "video" <> _} = media) do
    %{
      "type" => "Video",
      "mediaType" => media.media_type,
      "url" => full_url(Bonfire.Files.DocumentUploader, media),
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
      "url" => full_url(Bonfire.Files.DocumentUploader, media),
      "name" => media.metadata["label"]
    }
  end

  def ap_publish_activity(other) do
    debug(other, "Skip unrecognised media")
    nil
  end

  def ap_receive_attachments(creator, attachments) when is_list(attachments),
    do:
      attachments
      |> Enum.map(&ap_receive_attachments(creator, &1))
      |> List.flatten()
      |> Enums.filter_empty([])

  def ap_receive_attachments(
        %{character: %{peered: %{canonical_uri: actor_url}}} = creator,
        %{"name" => "Live stream preview", "url" => _gif_url} = attachment
      ) do
    # special case for owncast stream
    # TODO: a better way?
    Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(creator, actor_url)
  end

  def ap_receive_attachments(creator, %{"url" => urls} = attachment) when is_list(urls) do
    attachment = Map.drop(attachment, ["url"])

    urls
    |> Enum.map(fn
      %{} = url ->
        ap_receive_attachments(creator, Map.merge(attachment, url))

      url when is_binary(url) ->
        ap_receive_attachments(creator, Map.merge(attachment, %{"href" => url}))

      other ->
        error(other, "unexpected url data")
        nil
    end)
    |> List.flatten()
    |> Enums.filter_empty([])
  end

  def ap_receive_attachments(creator, %{"url" => %{} = url} = attachment) do
    ap_receive_attachments(creator, Map.drop(attachment, ["url"]) |> Map.merge(url))
  end

  def ap_receive_attachments(creator, url) when is_binary(url) do
    ap_receive_attachments(creator, %{"href" => url})
  end

  def ap_receive_attachments(creator, %{} = attachment) do
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
               metadata: %{
                 label: attachment["name"],
                 blurhash: attachment["blurhash"]
               }
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

  def ap_receive_attachments(_creator, nil) do
    nil
  end

  def ap_receive_attachments(_creator, attachment) do
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
