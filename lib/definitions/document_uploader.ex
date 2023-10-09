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
    :noaction
  end

  def transform(:thumbnail, {%{file_name: filename}, _scope}) do
    if String.ends_with?(filename, ".pdf") do
      debug(filename, "extract a thumbnail")
      # &Bonfire.Files.Image.Edit.thumbnail_image/2
      Bonfire.Files.Image.Edit.thumbnail_pdf(filename)
    else
      debug(filename, "do not transform")
      :noaction
    end
  end

  def storage_dir(_, {_file, user_id}) when is_binary(user_id) do
    "data/uploads/#{user_id}/docs"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback
      ["application/pdf"]
    )
  end
end
