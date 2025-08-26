defmodule Bonfire.Files.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

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
    access_key_id = System.get_env("UPLOADS_S3_ACCESS_KEY_ID")
    secret_access_key = System.get_env("UPLOADS_S3_SECRET_ACCESS_KEY")
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

      if config_env() not in [:test, :dev] || System.get_env("USE_S3") in ["true", "1", "yes"] do
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

    image_media = Bonfire.Files.MimeTypes.image_media()
    video_media = Bonfire.Files.MimeTypes.video_media()
    extra_media = Bonfire.Files.MimeTypes.extra_media()

    all_allowed_media =
      Map.merge(image_media, video_media)
      |> Map.merge(extra_media)

    all_allowed_media_types = all_allowed_media |> Map.keys()

    all_allowed_media_extensions =
      all_allowed_media |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.map(&".#{&1}")

    image_media_types = image_media |> Map.keys()

    image_media_extensions =
      image_media |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.map(&".#{&1}")

    video_media_types = video_media |> Map.keys()

    video_media_extensions =
      video_media |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.map(&".#{&1}")

    config :bonfire_files,
      image_media_types: image_media_types,
      image_media_extensions: image_media_extensions,
      max_upload_size: System.get_env("UPLOAD_LIMIT", "20") |> String.to_integer(),
      max_user_images_file_size:
        System.get_env("UPLOAD_LIMIT_VIDEOS", "5") |> String.to_integer(),
      max_user_video_file_size:
        System.get_env("UPLOAD_LIMIT_VIDEOS", "20") |> String.to_integer(),
      all_allowed_media_types: all_allowed_media_types,
      all_allowed_media_extensions: all_allowed_media_extensions

    config :bonfire_files, Bonfire.Files.DocumentUploader,
      allowed_media_types: all_allowed_media_types,
      allowed_media_extensions: all_allowed_media_extensions

    config :bonfire_files, Bonfire.Files.VideoUploader,
      allowed_media_types: video_media_types,
      allowed_media_extensions: video_media_extensions

    config :bonfire_files, Bonfire.Files.IconUploader,
      allowed_media_types: image_media_types,
      allowed_media_extensions: image_media_extensions

    config :bonfire_files, Bonfire.Files.ImageUploader,
      allowed_media_types: image_media_types,
      allowed_media_extensions: image_media_extensions,
      max_width: System.get_env("IMAGE_MAX_W", "700"),
      max_height: System.get_env("IMAGE_MAX_H", "700")

    # NOTE: this is avoid LV uploads failing with `invalid accept filter provided to allow_upload. Expected a file extension with a known MIME type.`
    # NOTE2: seems this needs to be compile-time
    # config :mime, :types, Map.merge(%{
    #   "application/json" => ["json"],
    #   "application/activity+json" => ["activity+json"],
    #   "application/ld+json" => ["ld+json"],
    #   "application/jrd+json" => ["jrd+json"]
    # }, all_allowed_media)
  end
end
