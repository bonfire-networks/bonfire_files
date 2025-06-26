defmodule Bonfire.Files.MimeTypes do
  def supported_media,
    do:
      Map.merge(image_media(), video_media())
      |> Map.merge(extra_media())

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
      "text/plain" => ["txt", "text", "log", "asc"],
      "text/markdown" => ["md", "mkd", "markdown", "livemd"],

      # doc
      "text/csv" => ["csv"],
      "text/tab-separated-values" => ["tsv"],
      "application/pdf" => ["pdf"],
      "application/rtf" => ["rtf"],

      # "application/msword"=> ["doc", "dot"],
      # "application/vnd.openxmlformats-officedocument.wordprocessingml.document"=> ["docx"],
      # "application/vnd.ms-excel"=> ["xls"],
      # "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"=> ["xlsx"],
      # "application/vnd.oasis.opendocument.presentation"=> ["odp"],
      # "application/vnd.oasis.opendocument.spreadsheet"=> ["ods"],
      # "application/vnd.oasis.opendocument.text"=> ["odt"],

      "text/x-vcard" => ["vcf"],
      "application/ics" => ["vcs", "ics"],
      "application/epub+zip" => ["epub"],
      "application/x-mobipocket-ebook" => ["prc", "mobi"],

      # archives
      # "application/x-tar"=> ["tar"],
      # "application/x-bzip"=> ["bzip"],
      # "application/x-bzip2"=> ["bzip2"],
      # "application/gzip"=> ["gz", "gzip"],
      # "application/zip"=> ["zip"],
      # "application/rar"=> ["rar"],
      # "application/vnd.rar"=> ["rar"],
      # "application/x-7z-compressed"=> ["7z"],

      # audio
      "audio/mpeg" => ["mpa", "mp2"],
      "audio/m4a" => ["m4a"],
      "audio/mp4" => ["m4a", "mp4"],
      "audio/x-m4a" => ["m4a"],
      "audio/aac" => ["aac"],
      "audio/mp3" => ["mp3"],
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
