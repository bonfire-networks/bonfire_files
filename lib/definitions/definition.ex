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
      import Untangle
      alias Bonfire.Files
      alias Bonfire.Files.FileDenied

      @acl :public_read

      def upload(user, file, attrs \\ %{}, opts \\ []) do
        Files.upload(__MODULE__, user, file, attrs, opts)
      end

      def remote_url(media, version \\ nil),
        do: Files.remote_url(__MODULE__, media, version)

      def blurred(media), do: Files.Blurred.blurred(media, definition: __MODULE__)

      def blurhash(media), do: Files.Blurred.blurhash(media, definition: __MODULE__)

      def validate(%{file_info: %{} = file_info}), do: validate(file_info)

      def validate(%{media_type: media_type, size: size}) do
        case {allowed_media_types(), max_file_size()} |> debug("validate_with") do
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

      def validate({_file, %{file_info: %{} = file_info}}) do
        validate(file_info)
      end

      def validate(other) do
        # TODO: `Files.extract_metadata` here as fallback?
        error(other, "File info not available so file type and/or size could not be validated")
      end
    end
  end
end
