import Config

# where do you want to store files? supports local storage, s3-compatible services, and more
# see https://hexdocs.pm/waffle/Waffle.html#module-setup-a-storage-provider
config :waffle,
  storage: Waffle.Storage.Local,
  # or {:system, "ASSET_HOST"}
  asset_host: "http://static.example.com"

image_media_types = [
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/svg+xml",
  "image/tiff"
]

all_media_types =
  image_media_types ++
    [
      "text/plain"
    ]

config :bonfire, Bonfire.Files.IconUploader, allowed_media_types: image_media_types

config :bonfire, Bonfire.Files.ImageUploader, allowed_media_types: image_media_types

config :bonfire, Bonfire.Files.DocumentUploader, allowed_media_types: all_media_types
