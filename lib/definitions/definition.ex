# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Definition do
  @moduledoc """
  Extension to Waffle.Definition, adding support for checking against media types
  parsed through magic bytes instead of file extensions, which can be modified by the user.

  You can still use validate/2 and other waffle callbacks.
  """

  @callback allowed_media_types() :: [binary] | :all

  defmacro __using__(_opts) do
    quote do
      @behaviour Bonfire.Files.Definition

      use Waffle.Definition

      use Bonfire.Files.Prepare

      use Entrepot.Uploader,
        storages: {Bonfire.Files.CapsuleIntegration.Attacher, :storages, [__MODULE__]}

      import Untangle
      alias Bonfire.Files
      alias Bonfire.Files.FileDenied

      @acl :public_read

      def upload(user, file, attrs \\ %{}, opts \\ []) do
        Files.upload(__MODULE__, user, file, attrs, opts)
      end

      def remote_url(media, version \\ nil)

      def remote_url(media, version),
        do: Files.remote_url(__MODULE__, media, version)

      def blurred(media), do: Files.Blurred.blurred(media, definition: __MODULE__)

      def blurhash(media), do: Files.Blurred.blurhash(media, definition: __MODULE__)

      def validate(media), do: Files.validate(media, allowed_media_types(), max_file_size())

      def storage_dir(_, {_file, %{user_id: user_id}}) when is_binary(user_id) do
        "data/uploads/#{user_id}/#{prefix_dir()}"
      end

      def storage_dir(_, {_file, _}) do
        "data/uploads/_/#{prefix_dir()}"
      end

      def build_options(upload, :cache, opts) do
        storage_dir = storage_dir(:cache, {upload, %{user_id: "cache"}})

        Keyword.put(opts, :prefix, storage_dir)
        |> debug()
      end

      def build_options(upload, :store, opts) do
        storage_dir = storage_dir(:store, {upload, %{user_id: opts[:user_id]}})

        opts
        |> Keyword.put(:prefix, storage_dir)
        |> Keyword.drop([:user_id])
        |> debug()
      end

      def build_metadata(%{thumbnail: %{} = thumbnail, default: %{}}, storage, opts) do
        with {:ok, %{id: id}} <-
               store(%Bonfire.Files.Versions{thumbnail: thumbnail}, storage, opts) do
          %{thumbnail: id}
        end
      end

      def build_metadata(upload, storage, opts) do
        # debug(upload)
        # debug(storage)
        # debug(opts)
        %{}
      end

      def attach(tuple, changeset) do
        Bonfire.Files.CapsuleIntegration.Attacher.attach(tuple, changeset, __MODULE__)
      end

      defoverridable storage_dir: 2
    end
  end
end
