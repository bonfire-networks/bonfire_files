# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.LocationMetadata do
  @moduledoc """
  Finds out whether a file still carries the location of where it was made: GPS in EXIF, XMP, QuickTime/MP4 atoms and the like.

  `find/1` prefers real tools, and runs a chain per format: `exiftool` (when present), then the tools of that format that are installed, then the byte scan as a last extra check. A positive from any step counts, as each step sees different structures (eg. `ffprobe` misses an MP4 `loci` box, which the scan finds). Each tool can be forced on or off with `Bonfire.Files.MediaEdit.choose_executable/2`. All steps look for the same things: coordinates (`GPSLatitude`, `GPSLongitude`, ISO 6709), not the word "location" or a place name.

  The tools per format (the format is the one found in the file's bytes, not its name):
  - JPEG, PNG, TIFF: `vipsheader -a` (EXIF GPS tags) and `vipsheader -f xmp-data` (XMP, also the compressed XMP of a PNG), ImageMagick `identify` (EXIF GPS tags) and `magick` (XMP, but not a compressed PNG one)
  - WebP: `vipsheader` and `webpmux -get xmp` (ImageMagick reads no WebP metadata when only pinging, and decoding the pixels costs too much)
  - HEIC: `vipsheader -a`, `identify`
  - GIF: `gifsicle --extension-info` (the XMP extension)
  - PDF: `pdfinfo -meta` (the XMP of the catalog, also when compressed)
  - MP4, MOV, WebM: `ffprobe` (ISO 6709 tags such as `location`)
  - SVG and anything else: the scan only

  The scan looks for:
  - an EXIF GPS block: a TIFF header (in a JPEG, PNG `eXIf`, WebP `EXIF` chunk, HEIC or a TIFF file) whose first directory points to a GPS directory (tag `0x8825`) that holds a latitude or longitude. Offsets and tag order are checked, so bytes that only look like a header are not taken for one;
  - the XMP/attribute keys `GPSLatitude` and `GPSLongitude` (`exif:`, `drone-dji:` and such), in any text: an XMP packet in an image, a PDF or an SVG;
  - in an MP4/QuickTime file, only the metadata boxes (`moov`, `meta`, `udta`, XMP `uuid`) are read, not the media data: the `©xyz` and `loci` location boxes, the `com.apple.quicktime.location.ISO6709` key, an ISO 6709 string (`+48.8584+002.2945`), and a GoPro `gpmd` or Google `camm` data track. In a WebM, the whole file is searched for the keys and an ISO 6709 string.

  Not covered by the scan: metadata inside a compressed stream (eg. a compressed XMP packet in a PDF or PNG), which only `exiftool`, `vipsheader` (PNG) and `pdfinfo` (PDF) read.
  """
  import Untangle
  require Bonfire.Common.Config
  alias Bonfire.Files.MediaEdit

  # read 8 MB at a time, with enough extra to see a marker that straddles two reads
  @chunk 8 * 1024 * 1024
  @overlap 64
  # the most read of any one MP4 box
  @max_box 64 * 1024 * 1024

  @xmp_keys ["GPSLatitude", "GPSLongitude", "GpsLatitude", "GpsLongitude"]
  @tiff_headers ["II*\0", "MM\0*"]
  @iso6709 ~r/[+-]\d{2}\.\d{2,}[+-]\d{3}\.\d{2,}/
  @iso6709_key "com.apple.quicktime.location.ISO6709"

  # the tags `exiftool` is asked for: coordinates only (a place name such as `City` is not one)
  @exiftool_tags [
    "-GPSLatitude",
    "-GPSLongitude",
    "-GPSPosition",
    "-GPSCoordinates",
    "-LocationInformation",
    "-Keys:Location",
    "-Matroska:Location"
  ]

  # the steps after `exiftool` and before the byte scan, per format: the tools that read that format's metadata
  @exif_xmp [:vips_exif, :vips_xmp, :identify, :magick]
  @format_tools %{
    jpeg: @exif_xmp,
    png: @exif_xmp,
    tiff: @exif_xmp,
    # ImageMagick reads no metadata of a WebP when only pinging it, and decoding the pixels would cost more than the other tools
    webp: [:vips_exif, :vips_xmp, :webpmux],
    heic: [:vips_exif, :identify],
    gif: [:gifsicle],
    pdf: [:pdfinfo],
    mp4: [:ffprobe],
    webm: [:ffprobe]
  }

  # the ImageMagick coder to name explicitly, so it reads the file as the type found in its bytes and never guesses another one
  @im_coders %{jpeg: "jpeg", png: "png", tiff: "tiff", heic: "heic"}
  @heic_brands ~w(heic heix hevc hevx heim heis mif1 msf1 avif avis)
  @gps_key ~r/GPS(Dest)?(Latitude|Longitude)/i

  @doc "What location the file at `path` still carries (a short description), or `nil` if none was found. Runs `exiftool`, the tools of the file's format and the byte scan, in that order, and stops at the first that finds a location."
  def find(path) when is_binary(path) do
    format = format(path)

    Enum.find_value([:exiftool] ++ Map.get(@format_tools, format, []) ++ [:scan], fn
      :scan -> if scan_on?(), do: scan(path)
      step -> step(step, path, format)
    end)
  end

  # the format as found in the first bytes of the file
  defp format(path) do
    case File.open(path, [:read, :binary, :raw], &pread(&1, 0, 16)) do
      {:ok, <<0xFF, 0xD8, _::binary>>} -> :jpeg
      {:ok, <<0x89, "PNG", _::binary>>} -> :png
      {:ok, <<"RIFF", _::32, "WEBP", _::binary>>} -> :webp
      {:ok, <<"GIF8", _::binary>>} -> :gif
      {:ok, <<"%PDF", _::binary>>} -> :pdf
      {:ok, <<"II*\0", _::binary>>} -> :tiff
      {:ok, <<"MM\0*", _::binary>>} -> :tiff
      {:ok, <<0x1A, 0x45, 0xDF, 0xA3, _::binary>>} -> :webm
      {:ok, <<_::32, "ftyp", brand::binary-4, _::binary>>} when brand in @heic_brands -> :heic
      {:ok, <<_::32, "ftyp", _::binary>>} -> :mp4
      _ -> :other
    end
  end

  defp step(:exiftool, path, _format) do
    "exiftool"
    |> cmd(["-a", "-G1", "-s", "-ee"] ++ @exiftool_tags ++ [path])
    |> first_line(~r/^\[[^\]]+\]\s+\S+\s+:/)
    |> found("exiftool")
  end

  defp step(:vips_exif, path, _format) do
    "vipsheader"
    |> cmd(["-a", path])
    |> first_line(~r/^exif-ifd\d+-GPS(Dest)?(Latitude|Longitude):\s*\S/)
    |> found("vipsheader")
  end

  # the XMP packet comes as base64 (the compressed XMP of a PNG already inflated), mixed with any error text
  defp step(:vips_xmp, path, _format) do
    "vipsheader"
    |> cmd(["-f", "xmp-data", path], nothing: ~r/field "xmp-data" not found/)
    |> case do
      out when is_binary(out) ->
        out
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          with true <- line =~ ~r/\A[A-Za-z0-9+\/=]{16,}\z/,
               {:ok, xmp} <- Base.decode64(line),
               [key | _] <- Regex.run(@gps_key, xmp) do
            "vipsheader: XMP #{key}"
          else
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  defp step(:identify, path, format) do
    with coder when is_binary(coder) <- @im_coders[format] do
      "identify"
      |> cmd(["-ping", "-format", "%[EXIF:GPS*]\n", "#{coder}:#{path}"])
      |> first_line(~r/^exif:GPS(Dest)?(Latitude|Longitude)=\S/)
      |> found("identify")
    end
  end

  # ImageMagick 7 only (`magick`): `identify` can not print the XMP profile
  defp step(:magick, path, format) do
    with coder when is_binary(coder) <- @im_coders[format] do
      "magick"
      |> cmd(["-ping", "#{coder}:#{path}", "xmp:-"], nothing: ~r/no APP1 data is available/)
      |> xmp_key("magick")
    end
  end

  defp step(:webpmux, path, _format) do
    "webpmux"
    |> cmd(["-get", "xmp", path, "-o", "/dev/stdout"], nothing: ~r/WEBP_MUX_NOT_FOUND/)
    |> xmp_key("webpmux")
  end

  defp step(:pdfinfo, path, _format) do
    "pdfinfo"
    |> cmd(["-meta", path])
    |> xmp_key("pdfinfo")
  end

  # the XMP extension is printed as a hex dump
  defp step(:gifsicle, path, _format) do
    case cmd("gifsicle", ["--extension-info", path]) do
      out when is_binary(out) ->
        out
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^\s+[0-9a-f]{8}:((?: [0-9a-f]{2,4})+)/, line) do
            [_, hex] -> [String.replace(hex, " ", "")]
            _ -> []
          end
        end)
        |> Enum.join()
        |> Base.decode16(case: :lower)
        |> case do
          {:ok, text} -> xmp_key(text, "gifsicle")
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # forced to the demuxer of the format found, and to local files, so a crafted file cannot make it open a playlist or a URL
  defp step(:ffprobe, path, format) do
    demuxer = if format == :webm, do: "matroska", else: "mov"

    "ffprobe"
    |> cmd([
      "-v",
      "error",
      "-protocol_whitelist",
      "file",
      "-f",
      demuxer,
      "-show_format",
      "-show_streams",
      path
    ])
    |> case do
      out when is_binary(out) ->
        out
        |> String.split("\n", trim: true)
        |> Enum.find(fn
          "TAG:" <> tag ->
            {key, value} =
              case String.split(tag, "=", parts: 2) do
                [key, value] -> {key, value}
                [key] -> {key, ""}
              end

            value =~ @iso6709 or key =~ @gps_key

          _ ->
            false
        end)
        |> found("ffprobe")

      _ ->
        nil
    end
  end

  # the byte scan runs unless a test forces it off with `Process.put([:bonfire_files, :choose_executable, "scan"], false)`
  defp scan_on?, do: ProcessTree.get([:bonfire_files, :choose_executable, "scan"]) != false

  # the output of `name`, or `nil` if the tool is absent (or forced off), or fails (it is then inconclusive, and the next step takes over). A failure is logged as a warning: it can not be run, runs past the timeout, or exits with an error status. Some tools exit with status 1 when the file has no such metadata: `nothing` is the message they print then, which is not a failure.
  defp cmd(name, args, opts \\ []) do
    with exe when not is_nil(exe) <- MediaEdit.choose_executable(:location, name),
         {:ok, exe} <- find_executable(name, exe) do
      run(
        name,
        exe,
        args,
        Bonfire.Common.Config.get([__MODULE__, :tool_timeout], to_timeout(second: 10)),
        opts[:nothing]
      )
    else
      _ -> nil
    end
  rescue
    e ->
      warn(
        args,
        "#{name} could not be run on #{subject(args)} (#{Exception.message(e)}); run with these arguments"
      )

      nil
  end

  # the file a tool was run on (the last argument), as a name short enough to survive a truncated log line
  defp subject(args) do
    case List.last(args) do
      path when is_binary(path) -> Path.basename(path)
      _ -> "a file"
    end
  end

  defp find_executable(name, exe) do
    case System.find_executable(to_string(exe)) do
      nil ->
        warn(exe, "#{name} is meant to be present, but its executable was not found")
        nil

      path ->
        {:ok, path}
    end
  end

  # a `Port` rather than `System.cmd`, which can not be stopped once started: past the timeout the tool's process is killed, so it does not linger
  defp run(name, exe, args, timeout, nothing) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    collect(port, name, os_pid, args, nothing, System.monotonic_time(:millisecond) + timeout, [])
  end

  defp collect(port, name, os_pid, args, nothing, deadline, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, name, os_pid, args, nothing, deadline, [acc | data])

      {^port, {:exit_status, 0}} ->
        IO.iodata_to_binary(acc)

      {^port, {:exit_status, status}} ->
        out = IO.iodata_to_binary(acc)

        if nothing && out =~ nothing do
          # the tool's normal answer for a file without that metadata
          out
        else
          warn(
            args,
            "#{name} exited with status #{status} on #{subject(args)} (#{String.slice(out, 0, 300)}); run with these arguments"
          )

          nil
        end
    after
      left ->
        warn(
          args,
          "#{name} ran past its timeout on #{subject(args)} and was stopped, so its answer is left out; run with these arguments"
        )

        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)

        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        nil
    end
  end

  defp first_line(out, regex) when is_binary(out),
    do: out |> String.split("\n", trim: true) |> Enum.find(&(&1 =~ regex))

  defp first_line(_, _), do: nil

  defp found(nil, _tool), do: nil
  defp found(line, tool), do: tool <> ": " <> String.trim(line)

  defp xmp_key(text, tool) when is_binary(text) do
    case Regex.run(@gps_key, text) do
      [key | _] -> "#{tool}: XMP #{key}"
      _ -> nil
    end
  end

  defp xmp_key(_, _), do: nil

  defp scan(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, fd} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case pread(fd, 0, 12) do
          # a HEIC image has its EXIF in an item, not in a metadata box
          <<_::32, "ftyp", brand::binary-4>> when brand in @heic_brands ->
            scan_stream(fd, size, 0, false)

          <<_::32, "ftyp", _::binary>> ->
            scan_boxes(fd, 0, size)

          <<0x1A, 0x45, 0xDF, 0xA3, _::binary>> ->
            scan_stream(fd, size, 0, true)

          _ ->
            scan_stream(fd, size, 0, false)
        end
      after
        File.close(fd)
      end
    else
      other ->
        error(other, "Could not read the file to look for a location")
        nil
    end
  end

  # whole file, a chunk at a time
  defp scan_stream(fd, size, offset, video?) when offset < size do
    last? = offset + @chunk >= size
    chunk = pread(fd, offset, @chunk + @overlap)

    found =
      chunk
      |> :binary.matches(@xmp_keys ++ @tiff_headers)
      |> Enum.find_value(fn {pos, _len} ->
        # a match in the overlap is the next chunk's
        if pos < @chunk or last?, do: classify(fd, chunk, pos, offset)
      end) || if(video?, do: iso6709(chunk), else: nil)

    found || if last?, do: nil, else: scan_stream(fd, size, offset + @chunk, video?)
  end

  defp scan_stream(_fd, _size, _offset, _video?), do: nil

  defp classify(fd, chunk, pos, offset) do
    case chunk do
      <<_::binary-size(pos), key::binary-size(11), _::binary>> when key in @xmp_keys ->
        "#{key} at byte #{offset + pos}"

      <<_::binary-size(pos), key::binary-size(12), _::binary>> when key in @xmp_keys ->
        "#{key} at byte #{offset + pos}"

      <<_::binary-size(pos), header::binary-size(4), _::binary>> when header in @tiff_headers ->
        if exif_gps?(fd, offset + pos), do: "EXIF GPS at byte #{offset + pos}"

      _ ->
        nil
    end
  end

  defp iso6709(bytes) do
    if Regex.match?(@iso6709, bytes), do: "ISO 6709 location"
  end

  # --- EXIF: a TIFF header at `base`, its first directory, the GPS directory it points to

  defp exif_gps?(fd, base) do
    with <<order::binary-2, magic::binary-2, ifd0::binary-4>> <- pread(fd, base, 8),
         endian when not is_nil(endian) <- endian(order, magic),
         [_ | _] = entries <- ifd_entries(fd, base, int(ifd0, endian), endian),
         {_tag, type, 1, value} when type in [4, 13] <-
           Enum.find(entries, &match?({0x8825, _, _, _}, &1)),
         [_ | _] = gps <- ifd_entries(fd, base, value, endian, 64) do
      # latitude, longitude, destination latitude, destination longitude
      Enum.any?(gps, fn {tag, _type, _count, _value} -> tag in [2, 4, 0x14, 0x16] end)
    else
      _ -> false
    end
  end

  defp endian("II", <<42, 0>>), do: :little
  defp endian("MM", <<0, 42>>), do: :big
  defp endian(_, _), do: nil

  # the entries of the directory at `offset`, if it is one: a plausible count, all in the file, tags in ascending order
  defp ifd_entries(fd, base, offset, endian, max \\ 512) do
    with <<count::binary-2>> <- pread(fd, base + offset, 2),
         count = int(count, endian),
         true <- count in 1..max//1,
         entries when byte_size(entries) == count * 12 <-
           pread(fd, base + offset + 2, count * 12) do
      entries =
        for <<tag::binary-2, type::binary-2, n::binary-4, value::binary-4 <- entries>>,
          do: {int(tag, endian), int(type, endian), int(n, endian), int(value, endian)}

      tags = Enum.map(entries, &elem(&1, 0))
      if tags == Enum.sort(tags), do: entries, else: []
    else
      _ -> []
    end
  end

  defp int(<<n::little-unsigned-integer-size(16)>>, :little), do: n
  defp int(<<n::big-unsigned-integer-size(16)>>, :big), do: n
  defp int(<<n::little-unsigned-integer-size(32)>>, :little), do: n
  defp int(<<n::big-unsigned-integer-size(32)>>, :big), do: n

  # --- MP4/QuickTime: walk the top-level boxes, reading only those that hold metadata

  defp scan_boxes(fd, pos, size) when pos + 8 <= size do
    with <<box_size::32, type::binary-4, rest::binary>> <- pread(fd, pos, 16),
         {header, box_size} <- box_size(box_size, rest, size - pos) do
      found =
        if type in ["moov", "meta", "udta", "uuid", "moof"] do
          scan_box(pread(fd, pos + header, min(box_size - header, @max_box)))
        end

      found || if box_size < 8, do: nil, else: scan_boxes(fd, pos + box_size, size)
    else
      _ -> nil
    end
  end

  defp scan_boxes(_fd, _pos, _size), do: nil

  # a size of 1 means the real one follows as 64 bits, 0 means the box runs to the end of the file
  defp box_size(1, <<big::64, _::binary>>, _left), do: {16, big}
  defp box_size(0, _rest, left), do: {8, left}
  defp box_size(n, _rest, _left), do: {8, n}

  defp scan_box(bytes) do
    keys = [@iso6709_key, "\xA9xyz", "loci", "gpmd", "camm"] ++ @xmp_keys

    bytes
    |> :binary.matches(keys)
    |> Enum.find_value(fn {pos, len} -> mp4_marker(bytes, pos, len) end) || iso6709(bytes)
  end

  defp mp4_marker(bytes, pos, len) do
    marker = binary_part(bytes, pos, len)
    before = if pos >= 4, do: binary_part(bytes, pos - 4, 4)
    after_marker = binary_part(bytes, pos + len, min(byte_size(bytes) - pos - len, 24))

    cond do
      marker == @iso6709_key or marker in @xmp_keys ->
        "#{marker} in the video's metadata"

      # `©xyz`: a 16-bit length and language, then the ISO 6709 text
      marker == "\xA9xyz" and
          match?(
            <<_::32, sign, digit, _::binary>> when sign in ~c"+-" and digit in ?0..?9,
            after_marker
          ) ->
        "©xyz location box"

      # `loci`: a full box (version and flags 0) of at least 20 bytes
      marker == "loci" and match?(<<_::32>>, before) and
        match?(<<0::32, _::binary>>, after_marker) and box_len(before) in 20..2048 ->
        "loci location box"

      # a sample entry of the GoPro or Google metadata track: six zero bytes, then data reference 1
      marker in ["gpmd", "camm"] and match?(<<0::48, 1::16, _::binary>>, after_marker) ->
        "#{marker} location data track"

      true ->
        nil
    end
  end

  defp box_len(<<n::32>>), do: n

  defp pread(fd, offset, len) do
    case :file.pread(fd, offset, len) do
      {:ok, data} -> data
      _ -> <<>>
    end
  end
end
