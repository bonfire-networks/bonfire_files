# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.LocationMetadataTest do
  @moduledoc """
  `Bonfire.Files.LocationMetadata.find/1` runs a chain per format: `exiftool`, the tools of the format, then the byte scan. These tests run every step alone on every fixture: each tool that covers a format must find the location by itself, the scan must find it too (except in compressed XMP, a documented gap), and no step may report a location in a clean file.

  Tools never run on the fixtures in place: they are copied to a temporary directory first.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  @moduletag :backend

  alias Bonfire.Files.LocationMetadata

  @fixtures Path.expand("fixtures/gps", __DIR__)

  @all_tools ~w(exiftool vipsheader identify magick webpmux gifsicle pdfinfo ffprobe)

  # the steps that cover each fixture, other than the byte scan
  @image_tools ~w(exiftool vipsheader identify magick)
  @with_location %{
    "gps.jpg" => @image_tools,
    "gps.png" => @image_tools,
    "gps.tiff" => @image_tools,
    "gps.webp" => ~w(exiftool vipsheader webpmux),
    "gps_anim.webp" => ~w(exiftool vipsheader webpmux),
    "gps.heic" => ~w(exiftool vipsheader identify),
    "gps_anim.gif" => ~w(exiftool gifsicle),
    "gps.pdf" => ~w(exiftool pdfinfo),
    "gps.mp4" => ~w(exiftool ffprobe),
    "gps.svg" => ~w(exiftool)
  }

  # the XMP is zlib-compressed (a PNG `iTXt` chunk, a PDF `FlateDecode` stream), so the bytes hold no `GPSLatitude`
  @compressed %{
    "gps_compressed_xmp.png" => ~w(exiftool vipsheader),
    "gps_compressed_xmp.pdf" => ~w(exiftool pdfinfo)
  }

  @without_location ~w(clean.jpg clean.png clean.gif clean.webp clean.tiff clean.pdf clean.svg clean.mp4)

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "location_metadata_fixtures_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    File.cp_r!(@fixtures, dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # `only`: the one tool left on (a name from `@all_tools`) with the byte scan off, so a hit can only come from that tool; `nil`: every tool off (the byte scan alone); `:all`: as installed, with the scan
  defp use_tools(:all) do
    for tool <- @all_tools, do: Process.put([:bonfire_files, :choose_executable, tool], nil)
    scan(true)
  end

  defp use_tools(nil) do
    use_tools(:none)
    scan(true)
  end

  defp use_tools(:none) do
    for tool <- @all_tools, do: Process.put([:bonfire_files, :choose_executable, tool], false)
    scan(false)
  end

  defp use_tools(only) do
    for tool <- @all_tools,
        do: Process.put([:bonfire_files, :choose_executable, tool], tool == only)

    scan(false)
  end

  defp scan(on?) do
    Process.put([:bonfire_files, :choose_executable, "scan"], on?)
    :ok
  end

  # a stand-in tool script, run in place of `tool`
  defp stand_in(tool, body) do
    script =
      Path.join(System.tmp_dir!(), "stand_in_#{tool}_#{System.unique_integer([:positive])}.sh")

    File.write!(script, "#!/bin/sh\n" <> body)
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm(script) end)
    Process.put([:bonfire_files, :choose_executable, tool], script)
    script
  end

  defp installed?(tool), do: System.find_executable(tool) != nil

  describe "a location in each fixture" do
    for {fixture, tools} <- @with_location do
      test "in #{fixture}, found by the chain as installed", %{dir: dir} do
        use_tools(:all)
        assert LocationMetadata.find(Path.join(dir, unquote(fixture)))
      end

      test "in #{fixture}, found by the byte scan alone", %{dir: dir} do
        use_tools(nil)
        assert LocationMetadata.find(Path.join(dir, unquote(fixture)))
      end

      for tool <- tools, System.find_executable(tool) do
        test "in #{fixture}, found by #{tool} alone", %{dir: dir} do
          use_tools(unquote(tool))
          assert LocationMetadata.find(Path.join(dir, unquote(fixture))) =~ ~r/^#{unquote(tool)}:/
        end
      end
    end
  end

  describe "a location in compressed XMP" do
    for {fixture, tools} <- @compressed do
      test "in #{fixture}, the chain as installed finds it when a tool reads it", %{dir: dir} do
        use_tools(:all)
        found = LocationMetadata.find(Path.join(dir, unquote(fixture)))
        if Enum.any?(unquote(tools), &installed?/1), do: assert(found), else: refute(found)
      end

      # a known gap: without a tool that inflates it, the byte scan does not see inside the stream
      test "in #{fixture}, the byte scan alone does not see it", %{dir: dir} do
        use_tools(nil)
        refute LocationMetadata.find(Path.join(dir, unquote(fixture)))
      end

      for tool <- tools, System.find_executable(tool) do
        test "in #{fixture}, found by #{tool} alone", %{dir: dir} do
          use_tools(unquote(tool))
          assert LocationMetadata.find(Path.join(dir, unquote(fixture))) =~ ~r/^#{unquote(tool)}:/
        end
      end
    end

    test "ImageMagick does not inflate a PNG's compressed XMP", %{dir: dir} do
      for tool <- ~w(identify magick) do
        use_tools(tool)
        refute LocationMetadata.find(Path.join(dir, "gps_compressed_xmp.png"))
      end
    end
  end

  describe "no location in a clean file" do
    for fixture <- @without_location do
      # each tool alone, with the scan off, answers `nil` (not an error), and none warns: a tool's normal "nothing found" exit is not a failure
      test "not in #{fixture}, on every step, and no tool warns", %{dir: dir} do
        path = Path.join(dir, unquote(fixture))

        log =
          capture_log(fn ->
            for only <- [:all, nil | @all_tools] do
              use_tools(only)

              refute LocationMetadata.find(path),
                     "#{inspect(only)} found a location in #{unquote(fixture)}"
            end
          end)

        refute log =~
                 ~r/could not be run|exited with status|executable was not found|ran past its timeout/,
               "a tool warned on #{unquote(fixture)}:\n#{log}"
      end
    end
  end

  describe "a tool that does not work" do
    test "a tool that exits with an error is logged as a warning, and the byte scan still finds the location",
         %{dir: dir} do
      use_tools(nil)
      stand_in("exiftool", "echo 'boom: broken tool' >&2\nexit 2\n")

      log =
        capture_log(fn ->
          assert LocationMetadata.find(Path.join(dir, "gps.jpg")) =~ "EXIF GPS"
        end)

      assert log =~ "[warning "
      assert log =~ "exiftool exited with status 2"
      assert log =~ "boom: broken tool"
      assert log =~ "gps.jpg"
    end

    test "a tool that is meant to be present but is not found is logged as a warning", %{dir: dir} do
      use_tools(nil)
      Process.put([:bonfire_files, :choose_executable, "gifsicle"], "no_such_tool_here")

      log = capture_log(fn -> assert LocationMetadata.find(Path.join(dir, "gps_anim.gif")) end)

      assert log =~ "gifsicle is meant to be present, but its executable was not found"
    end

    # the control for "found by #{"tool"} alone": a tool that prints nothing finds nothing, so those tests can fail
    test "a silent stand-in for a tool finds nothing in the fixtures it covers when the scan is off",
         %{dir: dir} do
      for {fixture, tools} <- @with_location, tool <- tools do
        use_tools(tool)
        stand_in(tool, "exit 0\n")

        refute LocationMetadata.find(Path.join(dir, fixture)),
               "a silent #{tool} found a location in #{fixture}"
      end
    end
  end

  describe "scanning the bytes" do
    setup do
      use_tools(nil)
      :ok
    end

    test "ordinary text about locations and GPS is not a location" do
      path =
        tmp_file(
          "text.txt",
          "location: the hall. GPS devices, latitude and longitude, 48.8584 and 2.2945, +12-100 is a range"
        )

      refute LocationMetadata.find(path)
    end

    test "a large file is scanned in chunks, and a marker across two chunks is found" do
      # the marker straddles the 8 MB chunk boundary
      padding = :binary.copy(<<0>>, 8 * 1024 * 1024 - 5)
      path = tmp_file("big.bin", [padding, "exif:GPSLatitude=\"1\"", :binary.copy(<<0>>, 100)])
      assert LocationMetadata.find(path)
    end

    test "a 100 MB file is scanned in well under a few seconds" do
      path = tmp_file("huge.bin", [:binary.copy(<<0>>, 100 * 1024 * 1024), "GPSLongitude"])
      {micros, found} = :timer.tc(fn -> LocationMetadata.find(path) end)
      assert found
      assert micros < 5_000_000, "scanning 100 MB took #{div(micros, 1000)} ms"
    end

    test "an MP4's media data is skipped: only its metadata boxes are read" do
      mp4 = File.read!(Path.join(@fixtures, "gps.mp4"))
      {before_moov, moov, _mdat} = split_mp4(mp4)
      mdat = [<<8 + 100 * 1024 * 1024::32, "mdat">>, :binary.copy(<<0>>, 100 * 1024 * 1024)]

      # media data first, as in a video that was not made streamable
      path = tmp_file("moov_last.mp4", [before_moov, mdat, moov])
      {micros, found} = :timer.tc(fn -> LocationMetadata.find(path) end)
      assert found
      assert micros < 1_000_000, "scanning the 100 MB MP4 took #{div(micros, 1000)} ms"

      # with every marker overwritten in the metadata, nothing is found
      clean = tmp_file("clean_moov.mp4", [before_moov, mdat, binary_replace_all(moov)])
      refute LocationMetadata.find(clean)
    end
  end

  describe "a tool that takes too long" do
    # a stand-in `exiftool` that records its process id, then sleeps far longer than the timeout
    setup do
      id = System.unique_integer([:positive])
      pid_file = Path.join(System.tmp_dir!(), "slow_tool_pid_#{id}")
      script = Path.join(System.tmp_dir!(), "slow_tool_#{id}.sh")
      File.write!(script, "#!/bin/sh\necho $$ > #{pid_file}\nexec sleep 30\n")
      File.chmod!(script, 0o755)
      on_exit(fn -> File.rm(script) && File.rm(pid_file) end)

      use_tools(nil)
      Process.put([:bonfire_files, :choose_executable, "exiftool"], script)
      Process.put([:bonfire_files, Bonfire.Files.LocationMetadata, :tool_timeout], 500)
      {:ok, pid_file: pid_file}
    end

    test "is stopped at the timeout, and the byte scan still finds a location", %{
      dir: dir,
      pid_file: pid_file
    } do
      {micros, found} = :timer.tc(fn -> LocationMetadata.find(Path.join(dir, "gps.jpg")) end)

      assert found =~ "EXIF GPS"
      assert micros < 5_000_000, "waited #{div(micros, 1000)} ms for a tool limited to 500 ms"
      assert File.exists?(pid_file), "the stand-in tool did not run"
      refute running?(File.read!(pid_file) |> String.trim()), "the tool was left running"
    end

    test "is stopped at the timeout, and a clean file has no location", %{
      dir: dir,
      pid_file: pid_file
    } do
      {micros, found} = :timer.tc(fn -> LocationMetadata.find(Path.join(dir, "clean.jpg")) end)

      refute found
      assert micros < 5_000_000
      refute running?(File.read!(pid_file) |> String.trim())
    end
  end

  # whether the OS process is still there (allowing a moment for it to go)
  defp running?(os_pid, tries \\ 10) do
    {_, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)

    cond do
      status != 0 -> false
      tries == 0 -> true
      true -> Process.sleep(100) && running?(os_pid, tries - 1)
    end
  end

  # What each step costs a clean file (the worst case: every step runs and none stops the chain), printed for the record
  describe "cost of each step" do
    @describetag :timing

    test "on a small JPEG and a 100 MB MP4", %{dir: dir} do
      jpeg = Path.join(dir, "clean.jpg")
      mp4 = Path.join(dir, "clean.mp4")
      {before_moov, moov, _rest} = split_mp4(File.read!(mp4))
      mdat = [<<8 + 100 * 1024 * 1024::32, "mdat">>, :binary.copy(<<0>>, 100 * 1024 * 1024)]
      big = tmp_file("big_clean.mp4", [before_moov, mdat, moov])

      lines =
        for {label, path} <- [{"small JPEG", jpeg}, {"100 MB MP4", big}],
            only <- [nil | @all_tools] ++ [:all] do
          use_tools(only)
          {micros, nil} = :timer.tc(fn -> LocationMetadata.find(path) end)
          "#{label} #{inspect(only || "scan alone")}: #{div(micros, 1000)} ms"
        end

      IO.puts("\nLocationMetadata step cost:\n" <> Enum.join(lines, "\n"))
      assert lines != []
    end
  end

  # the boxes of an MP4: everything before `moov`, `moov`, and what follows
  defp split_mp4(mp4), do: split_mp4(mp4, 0)

  defp split_mp4(mp4, pos) do
    <<_::binary-size(pos), size::32, type::binary-4, _::binary>> = mp4

    if type == "moov" do
      <<head::binary-size(pos), moov::binary-size(size), rest::binary>> = mp4
      {head, moov, rest}
    else
      split_mp4(mp4, pos + size)
    end
  end

  # the same box with every marker overwritten by as many spaces
  defp binary_replace_all(moov) do
    for marker <- ["GPSLatitude", "GPSLongitude", "xyz", "loci", "location", "+48.8584+002.2945"],
        reduce: moov do
      acc -> String.replace(acc, marker, String.duplicate("#", byte_size(marker)))
    end
  end

  defp tmp_file(name, data) do
    path =
      Path.join(
        System.tmp_dir!(),
        "location_metadata_#{System.unique_integer([:positive])}_#{name}"
      )

    File.write!(path, data)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end
end
