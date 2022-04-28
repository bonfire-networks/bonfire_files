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
      alias Bonfire.Files

      def upload(user, file, attrs \\ %{}, opts \\ []) do
        Files.upload(__MODULE__, user, file, attrs, opts)
      end

      def remote_url(media, version \\ nil), do: Files.remote_url(__MODULE__, media, version)

      def blurred(media), do: Files.Blurred.blurred(__MODULE__, media)

    end
  end
end
