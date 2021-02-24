# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImageUploader do
  use Bonfire.Files.Definition

  def transform(_file), do: :skip
end
