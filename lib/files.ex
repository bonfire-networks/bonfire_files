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

  ```
  iex> {:ok, media} = Bonfire.Files.upload(MyUploader, creator_or_context, %{path: "./150.png"})
  iex> media.media_type
  "image/png"
  iex> Bonfire.Files.remote_url(MyUploader, media)
  "/uploads/my/01F3AY6JV30G06BY4DR9BTW5EH"
  ```
  """

  use Needle.Mixin,
    otp_app: :bonfire_files,
    source: "bonfire_files"

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

  @cast [:media_id]
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

  defp maybe_do_upload(module, context, upload_file, attrs, opts) do
    debug(attrs, "uploads attrs")
    debug(upload_file, "upload_file")
    id = Needle.ULID.generate()

    upload_filename =
      Utils.e(upload_file, :path, nil) || Utils.e(upload_file, :filename, nil) ||
        upload_file

    file_extension = file_extension(Utils.e(attrs, :client_name, nil) || upload_filename)

    final_filename = "#{id}#{file_extension}"

    with {:ok, tmp_filename} <- maybe_move(opts[:move_original], upload_filename, final_filename),
         {:ok, file} <- fetch_file(module, tmp_filename),
         {:ok, file_info} <- extract_metadata(file),
         module when is_atom(module) and not is_nil(module) <-
           definition_module(module, file_info),
         #  :ok <- module.validate(file_info), # note: already called by Waffle
         upload_source <- %Plug.Upload{
           filename: final_filename,
           path: file.path,
           content_type: Map.get(file_info, :media_type)
         },
         # TODO: fully deprecate old Waffle based upload (for now we pass through it do apply validation+transformation)
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
  end

  def validate({_file, %{file_info: %{} = file_info}}, allowed_media_types, max_file_size) do
    validate(file_info, allowed_media_types, max_file_size)
  end

  def validate(other, _, _) do
    # TODO: `Files.extract_metadata` here as fallback?
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
    path |> Path.extname() |> String.downcase()
  end

  def file_extension_only(path) do
    file_extension(path) |> String.trim_leading(".")
  end

  defp insert({creator, object}, file, file_info, attrs) do
    insert(creator, file, file_info, attrs)
    ~> repo().insert(files_changeset(%{id: Types.ulid(object), media: ...}))
  end

  defp insert(creator, file, file_info, attrs) do
    Media.insert(creator, file, file_info, attrs)
  end

  defp context_id({creator, _object}) do
    Types.ulid(creator)
  end

  defp context_id(creator) do
    Types.ulid(creator)
  end

  defp definition_module(module \\ nil, file_info)

  defp definition_module(nil, %{media_type: media_type}) do
    image_types =
      Bonfire.Common.Config.get_ext(
        :bonfire_files,
        # allowed types of images
        :image_media_types,
        # fallback
        ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"]
      )

    all_allowed_types =
      Bonfire.Common.Config.get_ext(
        :bonfire_files,
        # all other
        :all_allowed_media_types,
        # fallback
        ["application/pdf"]
      )

    if Enum.member?(image_types, media_type) do
      debug(media_type, "using ImageUploader definition based on file type")
      Bonfire.Files.ImageUploader
    else
      if Enum.member?(all_allowed_types, media_type) do
        debug(
          media_type,
          "using DocumentUploader definition based on file type"
        )

        Bonfire.Files.DocumentUploader
      else
        {:error, FileDenied.new(media_type)}
      end
    end
  end

  defp definition_module(module, _file_info) do
    module
  end

  # defp insert_files(context, %Media{} = media, object) when is_binary(object) or is_map(object) do
  #   repo().insert_all(Files, conflict_target: :media) do
  # end

  defp files_changeset(pub \\ %Files{}, params) do
    pub
    |> Changeset.cast(params, @cast)
    |> Changeset.validate_required(@required)
    |> Changeset.assoc_constraint(:media)
    |> Changeset.unique_constraint(@cast)
  end

  @doc """
  Return the URL that a local file has.
  """
  @spec remote_url(atom, Media.t()) :: binary
  def remote_url(module \\ nil, media, version \\ :default)

  def remote_url(module, %{file: %Entrepot.Locator{id: id} = locator}, version)
      when is_binary(id),
      do: entrepot_remote_url(locator, version)

  def remote_url(_module, %Entrepot.Locator{id: id} = locator, version) when is_binary(id),
    do: entrepot_remote_url(locator, version)

  def remote_url(module, %Media{} = media, version) when is_atom(module) and not is_nil(module),
    do: module.url({media.path, %{creator_id: media.creator_id}}, version)

  def remote_url(module, media_id, version)
      when is_binary(media_id) and is_atom(module) and not is_nil(module) do
    case Media.one(id: media_id) do
      {:ok, media} ->
        remote_url(module, media, version)

      _ ->
        nil
    end
  end

  def remote_url(nil, %Media{metadata: %{"module" => definition}} = media, version) do
    case Types.maybe_to_atom(definition) do
      module when is_atom(module) and not is_nil(module) ->
        remote_url(module, media, version)

      _ ->
        nil
    end
  end

  def remote_url(nil, media_id, version) when is_binary(media_id) do
    case Media.one(id: media_id) do
      {:ok, media} ->
        remote_url(media, version)

      _ ->
        nil
    end
  end

  def remote_url(_, _, _), do: nil

  defp entrepot_remote_url(%Entrepot.Locator{id: id, storage: storage}, :default)
       when is_atom(storage) and not is_nil(storage) do
    with {:ok, file} <- storage.url(id) do
      file
    end
  end

  defp entrepot_remote_url(
         %Entrepot.Locator{id: id, storage: storage, metadata: %{} = metadata},
         version
       )
       when is_atom(storage) and not is_nil(storage) do
    # |> debug("metadata")
    with {:ok, file} <-
           (metadata
            |> Map.get(version) ||
              metadata
              |> Map.get(to_string(version)) ||
              id)
           |> storage.url() do
      file
    end
  end

  defp entrepot_remote_url(%{storage: storage} = locator, version)
       when is_binary(storage) do
    case storage
         # temporary
         |> String.replace("Capsule", "Entrepot")
         |> Types.maybe_to_module() do
      nil ->
        error(storage, "Storage module not found")

      storage ->
        entrepot_remote_url(Map.put(locator, :storage, storage), version)
    end
  end

  defp fetch_file(module, file) do
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

  def full_url(module, media) do
    case module.remote_url(media) do
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

    url = Utils.e(attachment, "href", nil) || Utils.e(attachment, "url", nil)
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
end
