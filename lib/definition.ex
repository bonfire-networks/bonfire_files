# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Definition do
  alias Bonfire.Files.Storage

  @callback transform(Storage.file_source()) :: {command :: atom, arguments :: [binary]} | :skip

  defmacro __using__(_opts) do
    quote do
      @behaviour Bonfire.Files.Definition
    end
  end
end
