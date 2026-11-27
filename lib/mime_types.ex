defmodule Bonfire.Files.MimeTypes do
  # TODO: how can we make these editable or at least extensible with ENV vars or in Settings UI?

  @doc """
  Normalizes detected WAV aliases so the stored type matches the upload allowlist.

  Other types are left unchanged; the detector remains responsible for identifying file contents.

      iex> Bonfire.Files.MimeTypes.normalize_type("audio/x-wav")
      "audio/wav"

      iex> Bonfire.Files.MimeTypes.normalize_type("audio/wav")
      "audio/wav"

      iex> Bonfire.Files.MimeTypes.normalize_type("application/octet-stream")
      "application/octet-stream"
  """
  def normalize_type("audio/x-wav"), do: "audio/wav"
  def normalize_type(media_type), do: media_type

  # NOTE: first extension will be considered canonical

  def allowed_media,
    do:
      Map.merge(image_media(), video_media())
      |> Map.merge(heif_media())
      |> Map.merge(extra_media())

  def supported_media,
    do:
      allowed_media()
      |> Map.merge(extra_known_types())

  # TODO: how can we make these editable or at least extensible with ENV vars?

  # NOTE: first extension will be considered canonical

  def image_media,
    do: %{
      "image/png" => ["png"],
      "image/apng" => ["apng"],
      "image/jpeg" => ["jpg", "jpeg"],
      "image/gif" => ["gif"],
      "image/svg+xml" => ["svg"],
      "image/webp" => ["webp"]
      # "image/tiff"=> "tiff"
    }

  # TODO: JPEG XL could be accepted the same way (converted to WebP on upload) once the security of its loader is sorted: libvips marks `jxlload` as untrusted
  @doc "Image types that are accepted by the image and emoji uploaders only because they are converted to WebP on upload (see `Bonfire.Files.MediaEdit.heif_to_webp/4`), so none is ever stored as it was uploaded."
  def heif_media,
    do: %{
      "image/heic" => ["heic"],
      "image/heif" => ["heif"],
      "image/avif" => ["avif"]
    }

  @doc "The capability (see `Bonfire.Files.MediaEdit.capabilities/0`) an image type needs to be accepted: `:heif` for HEIC, HEIF and AVIF, `:resize` for JPEG, PNG and WebP, `:svg` for SVG, `nil` for all else."
  def required_capability(type) when type in ["image/heic", "image/heif", "image/avif"], do: :heif

  def required_capability(type) when type in ["image/jpeg", "image/png", "image/webp"],
    do: :resize

  def required_capability("image/svg+xml"), do: :svg
  def required_capability(_), do: nil

  @doc "Splits a map of media types and their extensions into `{accepted, dropped}` by the capabilities given: `dropped` is a map of each type left out to the capability it lacks."
  def split_by_capabilities(media, capabilities) when is_map(media) do
    {kept, dropped} =
      Enum.split_with(media, fn {type, _exts} ->
        case required_capability(type) do
          nil -> true
          needed -> Map.get(capabilities, needed, false)
        end
      end)

    {Map.new(kept), Map.new(dropped, fn {type, _} -> {type, required_capability(type)} end)}
  end

  # the `ftyp` brand that says which of the HEIF family a file is, as the detector only knows some of them (an animated AVIF, brand `avis`, comes out as `video/quicktime`)
  @heif_brands %{
    "heic" => "image/heic",
    "heix" => "image/heic",
    "avif" => "image/avif",
    "avis" => "image/avif",
    "mif1" => "image/heif",
    "msf1" => "image/heif",
    "heim" => "image/heif",
    "heis" => "image/heif",
    "hevc" => "image/heif",
    "hevx" => "image/heif"
  }

  @doc "Sets the `media_type` of the metadata of a file to the HEIC, HEIF or AVIF type its `ftyp` brand gives, where the detector found another one (or none). Other files are left as they are."
  def put_heif_type(%{} = metadata, path) when is_binary(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]),
         <<_::32, "ftyp", brand::binary-4>> <-
           IO.binread(io, 12) |> tap(fn _ -> File.close(io) end),
         type when is_binary(type) <- Map.get(@heif_brands, brand) do
      Map.put(metadata, :media_type, type)
    else
      _ -> metadata
    end
  end

  def put_heif_type(metadata, _path), do: metadata

  def video_media,
    do: %{
      "video/mp4" => ["mp4", "mp4v", "mpg4"],
      "video/mpeg" => ["mpeg", "m1v", "m2v", "mpa", "mpe", "mpg"],
      "video/ogg" => ["ogg", "ogv"],
      "video/x-matroska" => ["mkv"],
      "application/x-matroska" => ["mkv"],
      "video/webm" => ["webm"],
      "video/3gpp" => ["3gp"],
      "video/3gpp2" => ["3g2"],
      "video/x-msvideo" => ["avi"],
      "video/quicktime" => ["mov", "qt"]
    }

  def extra_media,
    do: %{
      # docs
      "text/plain" => ["txt", "text", "log", "asc"],
      "text/markdown" => ["md", "mkd", "markdown", "livemd"],
      "text/csv" => ["csv"],
      "text/tab-separated-values" => ["tsv"],
      "application/pdf" => ["pdf"],

      # PIM
      "text/x-vcard" => ["vcf"],
      "application/ics" => ["vcs", "ics"],

      # ebooks
      "application/epub+zip" => ["epub"],
      "application/x-mobipocket-ebook" => ["prc", "mobi"],

      # audio
      "audio/mp3" => ["mp3"],
      "audio/mpeg" => ["mpa", "mp2"],
      "audio/m4a" => ["m4a"],
      "audio/mp4" => ["m4a", "mp4"],
      "audio/x-m4a" => ["m4a"],
      "audio/aac" => ["aac"],
      "audio/ogg" => ["ogg", "oga"],
      "audio/wav" => ["wav"],
      "audio/webm" => ["webm"],
      "audio/opus" => ["opus"],
      "audio/flac" => ["flac"],

      # feeds
      "application/atom+xml" => ["atom+xml"],
      "application/rss+xml" => ["rss+xml"],

      # json
      "application/json" => ["json"],
      "application/activity+json" => ["activity+json"],
      "application/ld+json" => ["ld+json"],
      "application/jrd+json" => ["jrd+json"]
    }

  # types we want the server to know about but not necessarily allow uploads for
  def extra_known_types,
    do: %{
      "image/tiff" => ["tiff"],

      # archives
      "application/x-tar" => ["tar"],
      "application/x-bzip" => ["bzip"],
      "application/x-bzip2" => ["bzip2"],
      "application/gzip" => ["gz", "gzip"],
      "application/zip" => ["zip"],
      "application/vnd.rar" => ["rar"],
      "application/x-7z-compressed" => ["7z"],

      # code
      "text/swiftui" => ["swiftui"],
      "text/jetpack" => ["jetpack"],
      "text/styles" => ["styles"],

      # docs
      "application/rtf" => ["rtf"],
      "application/msword" => ["doc", "dot"],
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ["docx"],
      "application/vnd.ms-excel" => ["xls"],
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => ["xlsx"],
      "application/vnd.oasis.opendocument.presentation" => ["odp"],
      "application/vnd.oasis.opendocument.spreadsheet" => ["ods"],
      "application/vnd.oasis.opendocument.text" => ["odt"]
    }

  @doc "The extension a file of this media type is stored under (the first one listed for it), or `nil` where the type has none listed."
  def canonical_extension(media_type) when is_binary(media_type) do
    case Map.get(supported_media(), media_type) do
      [ext | _] -> ext
      _ -> nil
    end
  end

  def canonical_extension(_), do: nil

  @doc "Whether `extension` (with or without its dot, any case) is one of those listed for the media type."
  def extension_of_type?(media_type, extension)
      when is_binary(media_type) and is_binary(extension) do
    extension = extension |> String.trim_leading(".") |> String.downcase()
    extension in List.wrap(Map.get(supported_media(), media_type))
  end

  def extension_of_type?(_, _), do: false

  # define which is preferred when more than one
  def unique_extension_for_mime do
    supported_media()
    |> Enum.flat_map(fn {mime, extensions} ->
      extensions
      |> Enum.reverse()
      |> Enum.map(fn ext -> {ext, mime} end)
    end)
    #   |> Enum.uniq_by(fn {x, _} -> x end)
    |> Map.new()
  end

  # %{
  #   "mkv" => "video/x-matroska",
  #   "m4a" => "audio/m4a",
  #   "mpa" => "audio/mpeg",
  #   "mp4" => "video/mp4",
  #   "ogg" => "video/ogg"
  # }

  #   # images
  #   "image/png" => ["png"],
  #   
  #   "image/jpeg" => ["jpg", "jpeg"],
  #   "image/gif" => ["gif"],
  #   "image/svg+xml" => ["svg"],
  #   "image/webp" => ["webp"],
  #   "image/tiff" => ["tiff"],
  #   # text
  #   "text/plain" => ["txt"],
  #   "text/markdown" => ["md"],
  #   # doc
  #   "text/csv" => ["csv"],
  #   "text/tab-separated-values" => ["tsv"],
  #   "application/pdf" => ["pdf"],
  #   "application/rtf" => ["rtf"],
  #   "application/msword" => ["doc", "dot"],
  #   "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ["docx"],
  #   "application/vnd.ms-excel" => ["xls"],
  #   "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => ["xlsx"],
  #   "application/vnd.oasis.opendocument.presentation" => ["odp"],
  #   "application/vnd.oasis.opendocument.spreadsheet" => ["ods"],
  #   "application/vnd.oasis.opendocument.text" => ["odt"],
  #   "application/ics" => []
  #   "application/epub+zip" => ["epub"],
  #   "application/x-mobipocket-ebook"=>["mobi"],

  #   # audio
  #   "audio/aac" => ["aac"],
  #   "audio/mpeg" => ["mpa", "mp2"],
  #   "audio/mp3" => ["mp3"],
  #   "audio/ogg" => ["oga"],
  #   "audio/wav" => ["wav"],
  #   "audio/m4a" => ["m4a"],
  #   "audio/x-m4a" => ["m4a"],
  #   "audio/mp4" => ["m4a", "mp4"],
  #   # "audio/webm"=> ["webm"],
  #   "audio/opus" => ["opus"],
  #   "audio/flac" => ["flac"],
  #   # video
  #   "video/mp4" => ["mp4"],
  #   "video/mpeg" => ["mpeg"],
  #   "video/ogg" => ["ogg", "ogv"],
  #   "video/webm" => ["webm"],
  #   "video/x-matroska" => ["mkv"],
  #   "application/x-matroska" => ["mkv"]
end
