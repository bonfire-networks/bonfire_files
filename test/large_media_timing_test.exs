# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.LargeMediaTimingTest do
  @moduledoc """
  Opt-in benchmark of the upload privacy steps (the ffmpeg metadata strip in `MediaEdit.video_strip/1`, the location detection in `Bonfire.Files.LocationMetadata.find/1`, the refusal and the storage) on real, large videos. It asserts little: it prints timings, each line starting with `LMT|`.

  Excluded by default (tags `:benchmark`, which the test helper excludes, and `:large_media`). Run it with:

      LARGE_MEDIA_MP4=/path/to/video.mp4 just test extensions/bonfire_files/test/large_media_timing_test.exs --include benchmark --include large_media

  Env vars (a test is skipped when its variable is unset):
  - `LARGE_MEDIA_MP4`: a video of a few hundred MB, with no GPS. Goes through the full `Files.upload/5` path, as is and as a copy carrying a location.
  - `LARGE_MEDIA_MP4_BIG`: a video of several GB, read only: detection (both branches), exiftool with and without `-ee`, and the stream copy of `video_strip` into one temporary file, which is deleted at once. No upload.

  Disk: the files are never modified. At most one large temporary file exists at a time (plus the stored upload while it is measured); each is deleted right after. Nothing is run if less than `LARGE_MEDIA_MIN_FREE_GB` (default 5) GiB is free in the temporary directory.
  """
  use Bonfire.DataCase, async: false

  # `:benchmark` is what `RuntimeConfig.skip_test_tags/1` excludes by default; `:large_media` selects this file
  @moduletag :benchmark
  @moduletag :large_media
  @moduletag timeout: :timer.minutes(60)

  alias Bonfire.Files
  alias Bonfire.Files.{LocationMetadata, MediaEdit, VideoUploader}

  @tags ~w(-GPSLatitude -GPSLongitude -GPSPosition -GPSCoordinates -LocationInformation -Keys:Location -Matroska:Location)
  @location "+48.8584+002.2945/"

  describe "a video of a few hundred MB through Files.upload/5" do
    test "as is (no GPS), and as a copy with a GPS location" do
      with_env("LARGE_MEDIA_MP4", fn mp4 ->
        tmp = tmp_dir()
        scope = %{file_info: %{media_type: "video/mp4"}}

        try do
          puts("file", "#{mp4} #{mb(File.stat!(mp4).size)} MB")
          assert find(mp4, :exiftool) == nil, "the file already has a location"
          assert find(mp4, :scan) == nil

          # (a) as is
          measure_file("as is", mp4, scope, tmp)

          # (b) a copy with a QuickTime location key and a `©xyz` box
          gps = Path.join(tmp, "gps.mp4")
          ensure_free!(tmp)

          {_, 0} =
            System.cmd(
              "ffmpeg",
              ~w(-nostdin -hide_banner -loglevel error -i #{mp4} -map 0 -c copy -movflags use_metadata_tags -metadata location=#{@location} -metadata com.apple.quicktime.location.ISO6709=#{@location} #{gps}),
              stderr_to_stdout: true
            )

          assert find(gps, :exiftool), "the copy has no GPS"
          assert find(gps, :scan), "the byte scan misses the copy's GPS"
          measure_file("with GPS", gps, scope, tmp)

          # what a refusal costs (no ffmpeg to strip it): the upload runs up to the detection
          Bonfire.Common.Config.put([:bonfire_files, :max_user_video_file_size], 5000)
          Process.put([:bonfire_files, :choose_executable, "ffmpeg"], false)
          creator = fake_user!()

          {us, res} =
            :timer.tc(fn ->
              Files.upload(VideoUploader, creator, %{path: gps, filename: "gps.mp4"})
            end)

          Process.delete([:bonfire_files, :choose_executable, "ffmpeg"])
          puts("with GPS, no ffmpeg: upload refused", "#{ms(us)} ms #{inspect(elem(res, 0))}")
          cleanup(creator)
        after
          File.rm_rf(tmp)
        end
      end)
    end
  end

  describe "a video of several GB, read only" do
    test "detection, exiftool and the ffmpeg stream copy" do
      with_env("LARGE_MEDIA_MP4_BIG", fn mp4 ->
        tmp = tmp_dir()
        puts("big file", "#{mp4} #{mb(File.stat!(mp4).size)} MB")

        try do
          for branch <- [:exiftool, :scan] do
            {us, found} = :timer.tc(fn -> find(mp4, branch) end)
            puts("big: LocationMetadata.find (#{branch})", "#{ms(us)} ms found=#{inspect(found)}")
          end

          for {label, args} <- [
                {"exiftool restricted tags, no -ee", ["-a", "-G1", "-s"] ++ @tags},
                {"exiftool restricted tags, -ee", ["-a", "-G1", "-s", "-ee"] ++ @tags},
                {"exiftool all tags, no -ee", ["-a", "-G1", "-s"]},
                {"exiftool all tags, -ee", ["-a", "-G1", "-s", "-ee"]}
              ] do
            {us, {_out, rss}} = :timer.tc(fn -> run_timed("exiftool", args ++ [mp4]) end)
            puts("big: #{label}", "#{ms(us)} ms, peak RSS #{rss} MB")
          end

          ensure_free!(tmp)
          out = Path.join(tmp, "stripped.mp4")

          {ffmpeg, args_fun, _ext} =
            MediaEdit.video_strip(%{file_info: %{media_type: "video/mp4"}})

          {free0, _} = free_gb(tmp)
          poller = start_disk_poller(tmp)

          {us, {_o, rss}} = :timer.tc(fn -> run_timed(ffmpeg, args_fun.(mp4, out)) end)

          peak = stop_disk_poller(poller)
          size = File.stat!(out).size

          puts(
            "big: ffmpeg strip (video_strip args)",
            "#{ms(us)} ms, peak RSS #{rss} MB, output #{mb(size)} MB, peak extra disk in dir #{mb(peak)} MB, free before #{free0} GiB"
          )

          # detection on the stripped output too
          for branch <- [:exiftool, :scan] do
            {us, found} = :timer.tc(fn -> find(out, branch) end)
            puts("big: find on stripped (#{branch})", "#{ms(us)} ms found=#{inspect(found)}")
          end
        after
          File.rm_rf(tmp)
        end
      end)
    end
  end

  # --- one file through the full path

  defp measure_file(label, path, scope, tmp) do
    # the default video limit is 20 MB
    Bonfire.Common.Config.put([:bonfire_files, :max_user_video_file_size], 5000)

    {ffmpeg, args_fun, _} = MediaEdit.video_strip(scope)
    out = Path.join(tmp, "strip_#{label |> String.replace(" ", "_")}.mp4")
    ensure_free!(tmp)

    {us, {_o, rss}} = :timer.tc(fn -> run_timed(ffmpeg, args_fun.(path, out)) end)

    puts(
      "#{label}: ffmpeg strip alone",
      "#{ms(us)} ms, peak RSS #{rss} MB, output #{mb(File.stat!(out).size)} MB"
    )

    for branch <- [:exiftool, :scan] do
      {us, found} = :timer.tc(fn -> find(path, branch) end)

      puts(
        "#{label}: detect on original (#{branch})",
        "#{ms(us)} ms found=#{inspect(found && true)}"
      )

      {us, found} = :timer.tc(fn -> find(out, branch) end)
      puts("#{label}: detect on stripped (#{branch})", "#{ms(us)} ms found=#{inspect(found)}")
      assert found == nil, "the stripped file still has a location (#{branch}): #{found}"
    end

    File.rm!(out)

    for branch <- [:exiftool, :scan] do
      Process.put(
        [:bonfire_files, :choose_executable, "exiftool"],
        if(branch == :scan, do: false)
      )

      creator = fake_user!()
      sampler = start_rss_sampler()

      {us, res} =
        :timer.tc(fn ->
          Files.upload(VideoUploader, creator, %{path: path, filename: "video.mp4"})
        end)

      beam_peak = stop_rss_sampler(sampler)
      assert {:ok, _} = res

      stored = stored_files(creator)
      sizes = Enum.map_join(stored, ", ", &"#{Path.basename(&1)}=#{mb(File.stat!(&1).size)}MB")

      {dus, leaks} =
        :timer.tc(fn -> for f <- stored, l = find(f, :exiftool), do: {Path.basename(f), l} end)

      puts(
        "#{label}: Files.upload total (detection #{branch})",
        "#{ms(us)} ms, BEAM peak RSS #{beam_peak} MB, stored #{sizes}, exiftool re-check of stored #{ms(dus)} ms"
      )

      assert leaks == [], "stored with a location: #{inspect(leaks)}"
      cleanup(creator)
      Process.delete([:bonfire_files, :choose_executable, "exiftool"])
    end

    # everything but the strip and the exiftool detection: no ffmpeg (thumbnail excepted: it needs ffmpeg too)
    if label == "as is" do
      Process.put([:bonfire_files, :choose_executable, "ffmpeg"], false)
      Process.put([:bonfire_files, :choose_executable, "exiftool"], false)
      creator = fake_user!()

      {us, res} =
        :timer.tc(fn ->
          Files.upload(VideoUploader, creator, %{path: path, filename: "video.mp4"})
        end)

      puts(
        "#{label}: Files.upload with no ffmpeg (no strip, no thumbnail), scan detection",
        "#{ms(us)} ms #{inspect(elem(res, 0))}"
      )

      cleanup(creator)
      Process.delete([:bonfire_files, :choose_executable, "ffmpeg"])
      Process.delete([:bonfire_files, :choose_executable, "exiftool"])
    end
  end

  # --- helpers

  defp find(path, :exiftool) do
    Process.put([:bonfire_files, :choose_executable, "exiftool"], nil)
    LocationMetadata.find(path)
  end

  defp find(path, :scan) do
    prev = Process.get([:bonfire_files, :choose_executable, "exiftool"])
    Process.put([:bonfire_files, :choose_executable, "exiftool"], false)

    try do
      LocationMetadata.find(path)
    after
      if prev == nil,
        do: Process.delete([:bonfire_files, :choose_executable, "exiftool"]),
        else: Process.put([:bonfire_files, :choose_executable, "exiftool"], prev)
    end
  end

  # runs a command under `/usr/bin/time -l`, returning its output and its peak RSS in MB
  defp run_timed(cmd, args) do
    exe = System.find_executable(cmd) || cmd
    {out, status} = System.cmd("/usr/bin/time", ["-l", exe | args], stderr_to_stdout: true)
    assert status == 0, "#{cmd} failed: #{String.slice(out, 0, 500)}"

    rss =
      case Regex.run(~r/(\d+)\s+maximum resident set size/, out) do
        [_, b] -> mb(String.to_integer(b))
        _ -> nil
      end

    {out, rss}
  end

  defp with_env(var, fun) do
    case System.get_env(var) do
      nil -> IO.puts("LMT|skipped, #{var} is not set")
      path -> if File.regular?(path), do: fun.(path), else: flunk("#{var}=#{path} is not a file")
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "large_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp free_gb(dir) do
    {out, 0} = System.cmd("df", ["-k", dir])
    [_, _, _, avail | _] = out |> String.split("\n", trim: true) |> List.last() |> String.split()
    {Float.round(String.to_integer(avail) / 1_048_576, 1), out}
  end

  defp ensure_free!(dir) do
    min = String.to_integer(System.get_env("LARGE_MEDIA_MIN_FREE_GB") || "5")
    {free, _} = free_gb(dir)
    if free < min, do: flunk("only #{free} GiB free, stopping (LARGE_MEDIA_MIN_FREE_GB=#{min})")
  end

  defp start_disk_poller(dir) do
    parent = self()

    spawn_link(fn ->
      poll = fn poll, peak ->
        receive do
          :stop -> send(parent, {:peak, peak})
        after
          200 ->
            size =
              dir
              |> Path.join("**/*")
              |> Path.wildcard()
              |> Enum.map(&(File.stat(&1) |> elem(1) |> Map.get(:size, 0)))
              |> Enum.sum()

            poll.(poll, max(peak, size))
        end
      end

      poll.(poll, 0)
    end)
  end

  defp stop_disk_poller(pid) do
    send(pid, :stop)

    receive do
      {:peak, peak} -> peak
    after
      5000 -> 0
    end
  end

  defp start_rss_sampler do
    parent = self()
    os_pid = System.pid()

    spawn_link(fn ->
      poll = fn poll, peak ->
        receive do
          :stop -> send(parent, {:rss_peak, peak})
        after
          100 ->
            {out, _} = System.cmd("ps", ["-o", "rss=", "-p", os_pid])

            kb =
              out
              |> String.trim()
              |> Integer.parse()
              |> then(fn
                {n, _} -> n
                _ -> 0
              end)

            poll.(poll, max(peak, kb))
        end
      end

      poll.(poll, 0)
    end)
  end

  defp stop_rss_sampler(pid) do
    send(pid, :stop)

    receive do
      {:rss_peak, kb} -> Float.round(kb / 1024, 0)
    after
      5000 -> nil
    end
  end

  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*") |> Enum.filter(&File.regular?/1)
  end

  defp cleanup(creator), do: File.rm_rf("data/uploads/#{creator.id}")

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
  defp ms(us), do: Float.round(us / 1000, 0)
  defp puts(label, text), do: IO.puts("LMT|#{label}: #{text}")
end
