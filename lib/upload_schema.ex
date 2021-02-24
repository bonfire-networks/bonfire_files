# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Files.GraphQL.UploadSchema do
  use Absinthe.Schema.Notation
  alias Bonfire.Files.GraphQL.UploadResolver

  import_types(Absinthe.Plug.Types)

  input_object :upload_input do
    field(:url, :string)
    field(:upload, :upload)
  end

  @desc "An uploaded file, may contain metadata."
  object :content do
    field(:id, non_null(:id))
    field(:media_type, non_null(:string))
    field(:metadata, :file_metadata)

    field(:url, non_null(:string)) do
      resolve(&UploadResolver.remote_url/3)
    end

    field(:is_public, non_null(:boolean)) do
      resolve(&UploadResolver.is_public/3)
    end

    field(:uploader, :user) do
      resolve(&UploadResolver.uploader/3)
    end

    field(:mirror, :content_mirror) do
      resolve(&UploadResolver.content_mirror/3)
    end

    field(:upload, :content_upload) do
      resolve(&UploadResolver.content_upload/3)
    end
  end

  object :content_mirror do
    field(:url, :string)
  end

  object :content_upload do
    field(:path, :string)
    field(:size, :integer)
  end

  @desc """
  Metadata associated with a file.

  None of the parameters are required and are filled depending on the
  file type.
  """
  object :file_metadata do
    field(:intrinsics, :file_intrinsics)
    # Image/Video
    field(:width_px, :integer)
    field(:height_px, :integer)
    # Audio
    field(:sample_rate_hz, :integer)
    field(:num_audio_channels, :integer)
  end

  @desc "More detailed metadata parsed from a file."
  object :file_intrinsics do
    # Audio
    field(:num_frames, :integer)
    field(:bits_per_sample, :integer)
    field(:byte_rate, :integer)
    field(:block_align, :integer)
    # Document
    field(:page_count, :integer)
    # Image
    field(:num_color_palette, :integer)
    field(:color_planes, :integer)
    field(:bits_per_pixel, :integer)
  end
end
