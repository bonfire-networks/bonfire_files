# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Definition do
  @moduledoc """
  Extension to Waffle.Definition, adding support for checking against media types
  parsed through magic bytes instead of file extensions, which can be modified by the user.

  You can still use validate/2 and other waffle callbacks.
  """

  @callback allowed_media_types() :: [binary] | :all
  @callback max_file_size() :: [integer] | :all

  defmacro __using__(_opts) do
    quote do
      @behaviour Bonfire.Files.Definition

      use Waffle.Definition

      use Bonfire.Files.Prepare

      use Entrepot.Uploader,
        storages: {Bonfire.Files.CapsuleIntegration.Attacher, :storages, [__MODULE__]}

      import Untangle
      use Bonfire.Common.Config
      use Bonfire.Common.Settings
      use Bonfire.Common.Localise
      alias Bonfire.Files
      alias Bonfire.Files.FileDenied

      @acl :public_read

      def upload(creator, file, attrs \\ %{}, opts \\ []) do
        Files.upload(__MODULE__, creator, file, attrs, opts)
      end

      def remote_url(media, version \\ nil)

      def remote_url(media, version),
        do: Files.remote_url(__MODULE__, media, version)

      def permanent_url(media, version \\ nil)

      def permanent_url(media, version),
        do: Files.permanent_url(__MODULE__, media, version)

      # def delete_files(media, opts \\ [])
      # def delete_files(%Entrepot.Locator{}=media, opts), do: Bonfire.Files.entrepot_storage_apply(:delete, media)
      # def delete_files(%{path: path}, opts), do: delete({path, opts[:creator_id]}) # for old Waffle uploads

      def blurred(media), do: Files.Blurred.blurred(media, definition: __MODULE__)

      def blurhash(media), do: Files.Blurred.blurhash(media, definition: __MODULE__)

      def validate(media), do: Files.validate(media, allowed_media_types(), max_file_size())

      def storage_dir(_, {_file, %{creator_id: creator_id}}) when is_binary(creator_id) do
        "data/uploads/#{creator_id}/#{prefix_dir()}"
      end

      def storage_dir(_, {_file, _}) do
        "data/uploads/_/#{prefix_dir()}"
      end

      def build_options(upload, :cache, opts) do
        storage_dir = storage_dir(:cache, {upload, %{creator_id: "cache"}})

        Keyword.put(opts, :prefix, storage_dir)
        |> debug()
      end

      def build_options(upload, :store, opts) do
        storage_dir = storage_dir(:store, {upload, %{creator_id: opts[:creator_id]}})

        opts
        |> Keyword.put(:prefix, storage_dir)
        |> Keyword.drop([:creator_id])
        |> debug()
      end

      def build_metadata(%{thumbnail: %{} = thumbnail, default: %{}}, storage, opts) do
        with {:ok, %{id: id}} <-
               store(%Bonfire.Files.Versions{thumbnail: thumbnail}, storage, opts) do
          %{thumbnail: id}
        end
      end

      def build_metadata(%{default: %{path: path}}, storage, opts)
          when __MODULE__ in [
                 Bonfire.Files.ImageUploader,
                 Bonfire.Files.BannerUploader,
                 Bonfire.Files.IconUploader
               ] and is_binary(path) do
        if hash = Bonfire.Files.Blurred.make_blurhash(path) do
          %{
            blurhash: hash
          }
        else
          %{}
        end
        |> debug()
      end

      def build_metadata(upload, storage, opts) do
        debug(__MODULE__)
        debug(upload)
        debug(storage)
        debug(opts)
        %{}
      end

      def attach(tuple, changeset) do
        Bonfire.Files.CapsuleIntegration.Attacher.attach(tuple, changeset, __MODULE__)
      end

      defoverridable storage_dir: 2
    end
  end
end
