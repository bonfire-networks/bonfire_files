# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files do
  @moduledoc """
  This module contains general functions for handling files, and also an Ecto schema which is a multimixin for storing one or more media attached to a Pointable object.

  An uploader definition must be provided for each new upload, or will be automatically chosen based on the file type.

  A few definitions exist as defaults inside of this namespace, but you can also define
  your own - a `Bonfire.Files.Definition` is an extension of `Waffle.Definition`,
  however the `allowed_media_types/0` callback is added, forcing you to define
  what media types are accepted for these types of uploads.
  (You can also return `:all` to accept everything).

  To use the uploader:

  ```
  iex> {:ok, media} = Bonfire.Files.upload(MyUploader, context, %{path: "./150.png"})
  iex> media.media_type
  "image/png"
  iex> Bonfire.Files.remote_url(MyUploader, media)
  "/uploads/my/01F3AY6JV30G06BY4DR9BTW5EH"
  ```
  """

  use Pointers.Mixin,
    otp_app: :bonfire_files,
    source: "bonfire_files"
  require Pointers.Changesets
  use Arrows
  import Where

  alias Bonfire.Files
  alias Bonfire.Files.{
    Media,
    FileDenied,
  }

  alias Bonfire.Common.Utils
  alias Pointers.Pointer
  alias Ecto.Changeset
  alias Bonfire.Repo

  mixin_schema do
    belongs_to :media, Media, primary_key: true
  end

  @cast     [:media_id]
  @required [:media_id]

  @doc """
  Attempt to store a file, returning an upload, for any parent item that
  participates in the meta abstraction, providing the user/context of
  the upload.
  """
  def upload(module, context, file, attrs \\ %{}, opts \\ [])
  def upload(module, context, "http"<>_ = file, attrs, opts) do
    if opts[:skip_fetching_remote]==true or Bonfire.Common.Config.get!(:env) == :test do
      debug("Files - skip file handling and just insert url or path in DB")
      insert(context, %{path: file}, %{size: 0, media_type: "remote"}, attrs)
    else
      maybe_do_upload(module, context, file, attrs, opts)
    end
  end
  def upload(module, context, file, attrs, opts), do: maybe_do_upload(module, context, file, attrs, opts)

  defp maybe_do_upload(module, context, files, attrs, opts) when is_list(files) do
    files
    |> Enum.map(files, fn file ->
      maybe_do_upload(module, context, file, attrs, opts)
    end)
  end

  defp maybe_do_upload(module, context, file, attrs, opts) do

    file_extension = if attrs[:client_name], do: attrs[:client_name] |> Path.extname() |> String.downcase() |> String.pad_leading(1, ".")

    with  {:ok, file} <- fetch_file(module, file),
          {:ok, file_info} <- extract_metadata(file),
          module when is_atom(module) and not is_nil(module) <- definition_module(module, file_info),
          :ok <- verify_media_type(module, file_info),
          id <- Pointers.ULID.generate(),
          {:ok, new_path} <- module.store({
            %Plug.Upload{filename: "#{id}#{file_extension}", path: file.path},
            context_id(context)}) do

      insert(context, %{file | path: new_path}, file_info, Map.put(attrs, :id, id))

    else
      other ->
        error(other)
    end
  end

  defp insert({user, object}, file, file_info, attrs) do
    insert(user, file, file_info, attrs)
    ~> Repo.insert(files_changeset(%{id: Utils.ulid(object), media: ...}))
  end

  defp insert(user, file, file_info, attrs) do
    Media.insert(user, file, file_info, attrs)
  end

  defp context_id({user, _object}) do
    Utils.ulid(user)
  end
  defp context_id(user) do
    Utils.ulid(user)
  end

  defp definition_module(module \\ nil, file_info)
  defp definition_module(nil, %{media_type: media_type}) do
    image_types = Bonfire.Common.Config.get_ext(:bonfire_files,
      :image_media_types, # allowed types of images
      ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"] # fallback
    )

    all_allowed_types = Bonfire.Common.Config.get_ext(:bonfire_files,
      :all_allowed_media_types, # all other
      ["application/pdf"] # fallback
    )

    if Enum.member?(image_types, media_type) do
      debug(media_type, "using ImageUploader definition based on file type")
      Bonfire.Files.ImageUploader
    else
      if Enum.member?(all_allowed_types, media_type) do
        debug(media_type, "using DocumentUploader definition based on file type")
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
  #   Repo.insert_all(Files, conflict_target: :media) do
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
  def remote_url(module, media, version \\ nil)

  def remote_url(module, %Media{} = media, version),
    do: module.url({media.path, media.user_id}, version)

  def remote_url(module, media_id, version) when is_binary(media_id) do
    case Media.one(id: media_id) do
      {:ok, media} ->
        remote_url(module, media, version)

      _ ->
        nil
    end
  end

  def remote_url(_, _, _), do: nil

  defp fetch_file(module, file) do
    file
    |> Bonfire.Common.Utils.input_to_atoms()
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

  def verify_media_type(definition, %{media_type: media_type}) do
    case definition.allowed_media_types() do
      :all -> :ok

      types ->
        if Enum.member?(types, media_type) do
          :ok
        else
          {:error, FileDenied.new(media_type)}
        end
    end
  end

  def data_url(content, mime_type) do
    image_base64 = Base.encode64(content)
    ["data:", mime_type, ";base64,", image_base64]
  end

  def full_url(module, media) do
    case module.remote_url(media) do
      "/"<>_ = path -> Bonfire.Common.URIs.base_url()<>path
      url -> url
    end
  end

  def ap_publish_activity(medias) when is_list(medias) do
    Enum.map(medias, &ap_publish_activity/1)
  end

  def ap_publish_activity(%Media{media_type: "image"<>_} = media) do
    %{
        "type"=> "Image",
        "mediaType"=> media.media_type,
        "url"=> full_url(Bonfire.Files.ImageUploader, media),
        "name"=> media.metadata["label"]
    }
  end

  def ap_publish_activity(%Media{media_type: "audio"<>_} = media) do
    %{
        "type"=> "Audio",
        "mediaType"=> media.media_type,
        "url"=> full_url(Bonfire.Files.DocumentUploader, media),
        "name"=> media.metadata["label"]
    }
  end

  def ap_publish_activity(%Media{media_type: "video"<>_} = media) do
    %{
        "type"=> "Video",
        "mediaType"=> media.media_type,
        "url"=> full_url(Bonfire.Files.DocumentUploader, media),
        "name"=> media.metadata["label"]
    }
  end

  def ap_publish_activity(%Media{} = media) do
    %{
        "type"=> "Document",
        "mediaType"=> media.media_type,
        "url"=> full_url(Bonfire.Files.DocumentUploader, media),
        "name"=> media.metadata["label"]
    }
  end

  # TODO: put somewhere more reusable
  def ap_receive_attachments(creator, attachments) when is_list(attachments), do: Enum.map(attachments, &ap_receive_attachments(creator, &1)) |> Utils.filter_empty([])
  def ap_receive_attachments(creator, %{"url"=>url} = attachment) do
    with {:ok, uploaded} <- upload(definition_module(%{media_type: attachment["mediaType"]}), creator, url, %{client_name: url, metadata: %{"label"=>attachment["name"]}}) # TODO: don't save empty label
    |> debug("uploaded") do
      uploaded
    else e ->
      error(e, "Could not upload #{url}")
      nil
    end
  end
  def ap_receive_attachments(_creator, attachment) do
    error(attachment, "Dunno how to handle this")
    nil
  end


end
