# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.DocumentUploader do
  @doc """
  Definition for any type of document, allows most media types
  that support documents, archives, video and audio.
  """

  use Bonfire.Files.Definition

  @versions [:default, :thumbnail]

  def transform(:default, _) do
    :noaction
  end

  def transform(:thumbnail, {%{file_name: "http" <> _ = filename}, _scope}) do
    :skip
  end

  def transform(:thumbnail, {%{file_name: filename}, _scope}) do
    if String.ends_with?(filename, ".pdf") do
      debug(filename, "extract a thumbnail")
      Bonfire.Files.MediaEdit.thumbnail_pdf(filename) || :skip
    else
      debug(filename, "do not transform")
      :skip
    end
  end

  def prefix_dir() do
    "docs"
  end

  @impl true
  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback
      ["application/pdf"]
    )
  end

  @impl true
  def max_file_size do
    Files.normalise_size(Bonfire.Common.Config.get([:bonfire_files, :max_docs_file_size]), 8)
  end
end
