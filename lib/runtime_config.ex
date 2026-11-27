defmodule Bonfire.Files.RuntimeConfig do
  use Bonfire.Common.Localise
  require Untangle

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @yes? ~w(true yes 1)

  def config do
    import Config

    config :unfurl, Unfurl.Oembed,
      extra_providers: [
        %{
          "provider_name" => "Crossref",
          "provider_url" => "doi.org",
          "fetch_function" => {Bonfire.Files.DOI, :fetch},
          "endpoints" => [
            %{
              "schemes" =>
                Bonfire.Files.DOI.pub_id_and_uri_matchers()
                |> Map.values()
              #      "url" => "https://api.crossref.org/works/",
              #      "append_url" => true 
            }
          ]
        }
      ]

    # where do you want to store uploaded files? supports local storage, s3-compatible services, and more, see https://hexdocs.pm/waffle/Waffle.html#module-setup-a-storage-provider
    # an example s3 compatible service: https://www.scaleway.com/en/pricing/?tags=storage
    # The default is local storage.

    bucket = System.get_env("UPLOADS_S3_BUCKET")
    access_key_id = Bonfire.Common.EnvSecrets.env_or_file("UPLOADS_S3_ACCESS_KEY_ID")
    secret_access_key = Bonfire.Common.EnvSecrets.env_or_file("UPLOADS_S3_SECRET_ACCESS_KEY")
    role_arn = System.get_env("AWS_ROLE_ARN")

    if bucket && ((access_key_id && secret_access_key) || role_arn) do
      # Use s3-compatible cloud storage

      # specify the bucket's host and region (defaults to Scaleway Paris), see:
      # https://www.scaleway.com/en/docs/storage/object/quickstart/
      # https://docs.aws.amazon.com/general/latest/gr/rande.html
      region = System.get_env("UPLOADS_S3_REGION", "fr-par")
      host = System.get_env("UPLOADS_S3_HOST", "s3.#{region}.scw.cloud")
      scheme = System.get_env("UPLOADS_S3_SCHEME", "https://")
      port = System.get_env("UPLOADS_S3_PORT", "443")
      s3_url = System.get_env("UPLOADS_S3_URL")
      default_asset_url = System.get_env("UPLOADS_S3_DEFAULT_URL", "#{scheme}#{bucket}.#{host}/")

      if config_env() not in [:test, :dev] || System.get_env("USE_S3") in @yes? do
        IO.puts("Note: uploads will be stored in s3: #{bucket} at #{host}")
        config :bonfire_files, :storage, :s3
      end

      # config :entrepot, Entrepot.Storages.Disk, root_dir: "data/uploads"

      config :entrepot, Entrepot.Storages.S3,
        bucket: bucket,
        bucket_as_host: s3_url == bucket,
        # the bucket name should be used in the hostname, along with the `host` name which will look like - <bucket>.<host> (eg `my-bucket.s3.fr-par.scw.cloud`)
        virtual_host: System.get_env("UPLOADS_S3_BUCKET_IN_HOSTNAME") == "true",
        unsigned: System.get_env("UPLOADS_S3_UNSIGNED_URLS") == "true"

      config :waffle,
        storage: Waffle.Storage.S3,
        bucket: bucket,
        asset_host: s3_url || default_asset_url

      config :ex_aws,
        http_client: ExAws.Request.Req,
        json_codec: Jason,
        region: region,
        s3: [
          scheme: scheme,
          host: host,
          region: region,
          port: port
        ]

      if !role_arn do
        # simple token based auth
        config :ex_aws,
          access_key_id: access_key_id,
          secret_access_key: secret_access_key
      else
        #  role-based authentication, see https://hexdocs.pm/ex_aws_sts/readme.html

        if access_key_id && secret_access_key do
          config :ex_aws,
            access_key_id: [{:awscli, "default", 30}],
            secret_access_key: [{:awscli, "default", 30}],
            awscli_auth_adapter: ExAws.STS.AuthCache.AssumeRoleCredentialsAdapter,
            awscli_credentials: %{
              "default" => %{
                role_arn: role_arn,
                access_key_id: access_key_id,
                secret_access_key: secret_access_key,
                source_profile: "default"
              }
            }
        else
          # use a web identity token to perform the assume role operation
          config :ex_aws,
            secret_access_key: [{:awscli, "default", 30}],
            access_key_id: [{:awscli, "default", 30}],
            awscli_auth_adapter: ExAws.STS.AuthCache.AssumeRoleWebIdentityAdapter,
            awscli_credentials: %{
              "default" => %{}
            }
        end
      end

      url_expiration_ttl =
        System.get_env("UPLOADS_S3_URL_EXPIRATION_TTL")
        |> case do
          # hours
          nil -> 6
          val -> String.to_integer(val)
        end

      url_cache_ttl =
        System.get_env("UPLOADS_S3_URL_CACHE_TTL")
        |> case do
          # a few minutes less to avoid dead links while a page is loading
          nil -> url_expiration_ttl - 0.2
          val -> String.to_integer(val)
        end

      config :bonfire_files,
        url_expiration_ttl: url_expiration_ttl,
        url_cache_ttl: url_cache_ttl,
        default_asset_url: default_asset_url,
        asset_url: if(s3_url != bucket, do: s3_url)
    else
      config :bonfire_files, :storage, :local

      config :waffle,
        storage: Waffle.Storage.Local,
        # or {:system, "ASSET_HOST"}
        asset_host: "/"
    end

    # the client Waffle uses to download a file added by URL
    config :waffle, http_client: Waffle.HTTPClient.Req

    # the types that are accepted depend on the tools this machine has (probed once, here at boot)
    capabilities = Bonfire.Files.MediaEdit.capabilities()
    media = media_config(capabilities)
    log_dropped_media(media.dropped)

    config :bonfire_files,
      strip_author_metadata: System.get_env("STRIP_IMAGE_AUTHOR_METADATA") in @yes?,
      image_media_types: media.global.image_media_types,
      image_media_extensions: media.global.image_media_extensions,
      max_upload_size: System.get_env("UPLOAD_LIMIT", "20") |> String.to_integer(),
      max_user_images_file_size:
        System.get_env("UPLOAD_LIMIT_IMAGES", "5") |> String.to_integer(),
      max_user_video_file_size:
        System.get_env("UPLOAD_LIMIT_VIDEOS", "20") |> String.to_integer(),
      # in megapixels: an image declaring more is refused before anything decodes it
      max_image_megapixels:
        System.get_env("UPLOAD_LIMIT_IMAGE_MEGAPIXELS", "100") |> String.to_integer(),
      all_allowed_media_types: media.global.all_allowed_media_types,
      all_allowed_media_extensions: media.global.all_allowed_media_extensions

    for {uploader, opts} <- media.uploaders do
      config :bonfire_files, uploader, opts
    end

    config :bonfire_files, Bonfire.Files.ImageUploader,
      max_width: System.get_env("IMAGE_MAX_W", "700"),
      max_height: System.get_env("IMAGE_MAX_H", "700")

    # a person's own media, one row each (the "Media" preload rule gives a feed filtered by `media_types` the `:per_media` rows), as the composer's media picker lists them. Declared here, beside the `media_types` filter it uses, and merged key by key into `bonfire_social`'s presets. `"attachment"` leaves link previews out. A plain map, since a `%FeedFilters{}` literal can't name a field this extension declares
    config :bonfire_social, Bonfire.Social.Feeds,
      feed_presets: [
        my_media: %{
          name: l("My media"),
          built_in: true,
          description: l("Media you shared"),
          filters: %{creators: [:by], media_types: ["attachment"], time_limit: 0},
          parameterized: %{creators: :by},
          exclude_from_nav: true,
          icon: "ph:images-duotone",
          # each file as a post shows it, as the other media feeds do (see `media_feed_assigns` in `bonfire_social`'s config)
          assigns: [custom_preview: Bonfire.UI.Social.Activity.MediaTileLive]
        }
      ]

    # NOTE: this is avoid LV uploads failing with `invalid accept filter provided to allow_upload. Expected a file extension with a known MIME type.`
    # NOTE2: seems this needs to be compile-time
    # config :mime, :types, Map.merge(%{
    #   "application/json" => ["json"],
    #   "application/activity+json" => ["activity+json"],
    #   "application/ld+json" => ["ld+json"],
    #   "application/jrd+json" => ["jrd+json"]
    # }, all_allowed_media)
  end

  @doc """
  The media types and extensions each uploader accepts, given what the machine can do (see `Bonfire.Files.MediaEdit.capabilities/0`): a type whose tool is missing is left out everywhere, so the composer's picker and the API's supported types don't offer what would be refused.

  Returns `%{global: [...], uploaders: %{Module => [allowed_media_types: ..., allowed_media_extensions: ...]}, dropped: %{type => capability}}`.
  """
  def media_config(capabilities) do
    alias Bonfire.Files.MimeTypes

    split = &MimeTypes.split_by_capabilities(&1, capabilities)

    {image_media, dropped_images} = split.(MimeTypes.image_media())
    {heif_media, dropped_heif} = split.(MimeTypes.heif_media())
    video_media = MimeTypes.video_media()
    extra_media = MimeTypes.extra_media()

    # everything a post can carry, including HEIC, HEIF and AVIF (converted to WebP on upload): what the composer lets a person pick
    all_allowed_media =
      image_media |> Map.merge(video_media) |> Map.merge(heif_media) |> Map.merge(extra_media)

    # the same without HEIC, HEIF and AVIF, for the uploader that stores a file as it is
    document_media = image_media |> Map.merge(video_media) |> Map.merge(extra_media)

    # avatars and banners refuse SVG: we can't make a raster copy of one, and other fediverse apps (eg. Mastodon) don't show an SVG avatar or banner
    profile_image_media = Map.delete(image_media, "image/svg+xml")

    # HEIC, HEIF and AVIF are accepted for posts and emoji only: converted to WebP on upload
    image_and_heif_media = Map.merge(image_media, heif_media)

    %{
      global: %{
        all_allowed_media_types: Map.keys(all_allowed_media),
        all_allowed_media_extensions: extensions(all_allowed_media),
        image_media_types: Map.keys(image_media),
        image_media_extensions: extensions(image_media)
      },
      uploaders: %{
        Bonfire.Files.DocumentUploader => allowed(document_media),
        Bonfire.Files.VideoUploader => allowed(video_media),
        Bonfire.Files.IconUploader => allowed(profile_image_media),
        Bonfire.Files.BannerUploader => allowed(profile_image_media),
        Bonfire.Files.InstanceIconUploader => allowed(image_media),
        Bonfire.Files.ImageUploader => allowed(image_and_heif_media),
        Bonfire.Files.EmojiUploader => allowed(image_and_heif_media)
      },
      dropped: Map.merge(dropped_images, dropped_heif)
    }
  end

  defp allowed(media),
    do: [allowed_media_types: Map.keys(media), allowed_media_extensions: extensions(media)]

  defp extensions(media),
    do: media |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.map(&".#{&1}")

  defp log_dropped_media(dropped) when dropped == %{}, do: :ok

  defp log_dropped_media(dropped) do
    reasons = %{
      heif: "no decoder for it (libvips with libheif, or ImageMagick with HEIC support)",
      resize: "no image resize tool (vips, ImageMagick or the Image library)",
      svg: "no SVG sanitiser"
    }

    dropped
    |> Enum.group_by(fn {_type, needed} -> needed end, fn {type, _} -> type end)
    |> Enum.each(fn {needed, types} ->
      Untangle.info(
        "Uploads of #{types |> Enum.sort() |> Enum.join(", ")} are not accepted: #{reasons[needed]}"
      )
    end)
  end
end
