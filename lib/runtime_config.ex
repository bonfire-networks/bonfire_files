defmodule Bonfire.Files.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    # where do you want to store uploaded files? supports local storage, s3-compatible services, and more, see https://hexdocs.pm/waffle/Waffle.html#module-setup-a-storage-provider
    # an example s3 compatible service: https://www.scaleway.com/en/pricing/?tags=storage
    # The default is local storage.

    if config_env() != :test and System.get_env("UPLOADS_S3_BUCKET") &&
         System.get_env("UPLOADS_S3_ACCESS_KEY_ID") &&
         System.get_env("UPLOADS_S3_SECRET_ACCESS_KEY") do
      # Use s3-compatible cloud storage

      bucket = System.get_env("UPLOADS_S3_BUCKET")

      # specify the bucket's host and region (defaults to Scaleway Paris), see:
      # https://www.scaleway.com/en/docs/storage/object/quickstart/
      # https://docs.aws.amazon.com/general/latest/gr/rande.html
      region = System.get_env("UPLOADS_S3_REGION", "fr-par")
      host = System.get_env("UPLOADS_S3_HOST", "s3.#{region}.scw.cloud")
      scheme = System.get_env("UPLOADS_S3_SCHEME", "https://")

      IO.puts("Note: uploads will be stored in s3: #{bucket} at #{host}")

      config :waffle,
        storage: Waffle.Storage.S3,
        bucket: bucket,
        asset_host: System.get_env("UPLOADS_S3_URL", "#{scheme}#{bucket}.#{host}/")

      config :ex_aws,
        json_codec: Jason,
        access_key_id: System.get_env("UPLOADS_S3_ACCESS_KEY_ID"),
        secret_access_key: System.get_env("UPLOADS_S3_SECRET_ACCESS_KEY"),
        region: region,
        s3: [
          scheme: scheme,
          host: host,
          region: region
        ]
    else
      config :waffle,
        storage: Waffle.Storage.Local,
        # or {:system, "ASSET_HOST"}
        asset_host: "/"
    end

    image_media_types = [
      "image/png",
      "image/jpeg",
      "image/gif",
      "image/svg+xml",
      "image/tiff"
    ]

    all_allowed_media_types =
      image_media_types ++
        [
          "text/plain",
          # doc
          "text/csv",
          "application/pdf",
          "application/rtf",
          "application/msword",
          "application/vnd.ms-excel",
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          "application/vnd.oasis.opendocument.presentation",
          "application/vnd.oasis.opendocument.spreadsheet",
          "application/vnd.oasis.opendocument.text",
          "application/epub+zip",
          # archives
          "application/x-tar",
          "application/x-bzip",
          "application/x-bzip2",
          "application/gzip",
          "application/zip",
          "application/rar",
          "application/x-7z-compressed",
          # audio
          "audio/mpeg",
          "audio/ogg",
          "audio/wav",
          "audio/webm",
          "audio/opus",
          # video
          "video/mp4",
          "video/mpeg",
          "video/ogg",
          "video/webm"
        ]

    config :bonfire_files, image_media_types: image_media_types
    config :bonfire_files, all_allowed_media_types: all_allowed_media_types

    config :bonfire_files, Bonfire.Files.DocumentUploader,
      allowed_media_types: all_allowed_media_types

    config :bonfire_files, Bonfire.Files.IconUploader, allowed_media_types: image_media_types

    config :bonfire_files, Bonfire.Files.ImageUploader,
      allowed_media_types: image_media_types,
      max_width: System.get_env("IMAGE_MAX_W", "700"),
      max_height: System.get_env("IMAGE_MAX_H", "700")
  end
end
