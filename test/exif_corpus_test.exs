# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ExifCorpusTest do
  @moduledoc """
  Opt-in run of the location detection and the upload path over a corpus of real image files, compared with exiftool. Each line it prints starts with `EXC|`.

  The corpus is the `tests/resources/` folder of exif-py (https://github.com/ianare/exif-py, code BSD-3-Clause, images mostly Wikimedia Commons under CC BY-SA). The images are never copied into this repository: they are read from a local checkout, and each is copied to a temporary folder before anything runs on it.

  Excluded by default (tags `:benchmark`, which the test helper excludes, and `:exif_corpus`). Run it with:

      EXIF_CORPUS_DIR=/path/to/exif-py/tests/resources just test extensions/bonfire_files/test/exif_corpus_test.exs --include benchmark --include exif_corpus

  Skipped when `EXIF_CORPUS_DIR` is unset or exiftool is missing. For every file:
  1. `LocationMetadata.find/1`, timed, compared with exiftool's own answer (agree, missed, false positive);
  2. `Files.upload/5` with the uploader chosen automatically: accepted or refused (and why), the stored files, whether any stored file still has GPS per exiftool, any crash or hang (`EXIF_CORPUS_TIMEOUT_S`, default 60).

  The test fails only on a stored file with GPS (a leak), a detection miss where exiftool finds GPS, a crash or a hang. False positives and refusals are printed, not failed.
  """
  use Bonfire.DataCase, async: false
  @moduletag :benchmark
  @moduletag :exif_corpus
  @moduletag timeout: :timer.minutes(60)

  alias Bonfire.Files
  alias Bonfire.Files.LocationMetadata

  @gps_tags ~w(-GPSLatitude -GPSLongitude -GPSPosition -GPSCoordinates -GPSDestLatitude -GPSDestLongitude)

  @dir System.get_env("EXIF_CORPUS_DIR")
  @files if @dir && File.dir?(@dir),
           do:
             @dir
             |> Path.join("**/*")
             |> Path.wildcard()
             |> Enum.filter(&File.regular?/1)
             |> Enum.sort(),
           else: []

  # one test per file: the database connection of a test is dropped after a couple of minutes, far less than the whole corpus takes. The rows are kept in `:persistent_term` and the report is printed when the module is done.
  setup_all do
    tmp = Path.join(System.tmp_dir!(), "exif_corpus_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    :persistent_term.put({__MODULE__, :rows}, [])
    start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    IO.puts("EXC|corpus: #{@dir}, #{length(@files)} files")

    on_exit(fn ->
      File.rm_rf(tmp)
      rows = :persistent_term.get({__MODULE__, :rows}, [])
      if rows != [], do: report(Enum.reverse(rows))
      :persistent_term.erase({__MODULE__, :rows})
    end)

    {:ok, tmp: tmp}
  end

  if is_nil(@dir) or not File.dir?(@dir || "") or is_nil(System.find_executable("exiftool")) do
    test "skipped: EXIF_CORPUS_DIR is not set (or not a folder), or exiftool is missing" do
      IO.puts("EXC|skipped, EXIF_CORPUS_DIR is not set (or not a folder), or exiftool is missing")
    end
  else
    for {file, i} <- Enum.with_index(@files) do
      @file_path file
      @file_index i
      test "#{Path.relative_to(file, @dir)}", %{tmp: tmp} do
        timeout = String.to_integer(System.get_env("EXIF_CORPUS_TIMEOUT_S") || "60") * 1000
        row = one(@file_path, @dir, tmp, @file_index, timeout)

        :persistent_term.put({__MODULE__, :rows}, [
          row | :persistent_term.get({__MODULE__, :rows}, [])
        ])

        failures = failures([row])
        assert failures == [], "corpus failures:\n" <> Enum.join(failures, "\n")
      end
    end
  end

  # --- one file

  defp one(file, dir, tmp, i, timeout) do
    rel = Path.relative_to(file, dir)
    ext = file |> Path.extname() |> String.downcase() |> String.trim_leading(".")
    truth = exif_gps?(file)
    IO.puts("EXC|start #{i} #{rel}")

    # (1) detection on a tmp copy
    copy = copy_to(file, tmp, "find_#{i}")
    {find_time, found} = guarded(timeout, fn -> LocationMetadata.find(copy) end)
    File.rm(copy)

    detection =
      case found do
        {:ok, result} -> classify(truth, result)
        other -> other
      end

    # (2) the upload, uploader chosen by Bonfire
    copy = copy_to(file, tmp, "up_#{i}")
    creator = fake_user!()

    {up_time, up} =
      guarded(timeout, fn ->
        Files.upload(nil, creator, %{path: copy, filename: Path.basename(file)}, %{})
      end)

    stored = stored_files(creator)
    leaks = for f <- stored, exif_gps?(f), do: Path.basename(f)
    File.rm_rf("data/uploads/#{creator.id}")
    File.rm(copy)

    outcome =
      case up do
        {:ok, {:ok, _}} ->
          :accepted

        {:ok, {:error, %Bonfire.Fail{code: code}}} ->
          {:refused, code}

        {:ok, {:error, e}} ->
          {:refused, short(e)}

        {:ok, [_ | _] = l} ->
          if Enum.all?(l, &match?({:ok, _}, &1)), do: :accepted, else: {:refused, short(l)}

        {:ok, other} ->
          {:refused, short(other)}

        other ->
          other
      end

    %{
      rel: rel,
      ext: ext,
      truth: truth,
      detection: detection,
      find_ms: find_time,
      outcome: outcome,
      up_ms: up_time,
      stored: Enum.map(stored, &Path.basename/1),
      leaks: leaks
    }
  end

  defp classify(true, nil), do: :missed
  defp classify(true, _), do: :agree
  defp classify(false, nil), do: :agree
  defp classify(false, _), do: :false_positive

  # runs `fun` in an unlinked task: {ms, {:ok, result}} | {ms, {:crash, reason}} | {ms, :hang}
  defp guarded(timeout, fun) do
    t0 = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(__MODULE__.Tasks, fn ->
        try do
          {:ok, fun.()}
        catch
          kind, reason ->
            {:crash, Exception.format(kind, reason, __STACKTRACE__) |> String.slice(0, 600)}
        end
      end)

    res =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, v}} -> {:ok, v}
        {:ok, {:crash, r}} -> {:crash, r}
        {:exit, reason} -> {:crash, inspect(reason) |> String.slice(0, 600)}
        nil -> :hang
      end

    {System.monotonic_time(:millisecond) - t0, res}
  end

  # exiftool's own answer: does the file have any GPS tag?
  defp exif_gps?(path) do
    {out, _} =
      System.cmd("exiftool", ["-n", "-a", "-G1", "-s", "-ee"] ++ @gps_tags ++ [path],
        stderr_to_stdout: true
      )

    out
    |> String.split("\n", trim: true)
    |> Enum.any?(&Regex.match?(~r/^\[(?!System)[^\]]+\]\s+(GPS|Coordinates)\w*\s*:\s*\S/, &1))
  end

  defp copy_to(file, tmp, prefix) do
    dest = Path.join(tmp, prefix <> "_" <> Path.basename(file))
    File.cp!(file, dest)
    dest
  end

  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*") |> Enum.filter(&File.regular?/1)
  end

  defp short(e), do: e |> inspect() |> String.slice(0, 120)

  # --- report

  defp report(rows) do
    IO.puts(
      "EXC|--- per file: path | exiftool GPS | detection | find ms | upload | upload ms | stored | leaks"
    )

    for r <- rows do
      IO.puts(
        "EXC|#{r.rel} | gps=#{r.truth} | #{inspect(r.detection)} | #{r.find_ms} | #{inspect(r.outcome)} | #{r.up_ms} | #{length(r.stored)} #{inspect(r.stored)} | #{inspect(r.leaks)}"
      )
    end

    IO.puts(
      "EXC|--- per format: ext count gps detected missed false_pos accepted refused(reasons) leaks crashes hangs | find ms median/max | upload ms median/max"
    )

    for {ext, rs} <- rows |> Enum.group_by(& &1.ext) |> Enum.sort(),
        do: IO.puts("EXC|" <> summary(ext, rs))

    IO.puts("EXC|" <> summary("TOTAL", rows))
  end

  defp summary(label, rs) do
    refused =
      for %{outcome: {:refused, why}} <- rs,
          reduce: %{},
          do: (acc -> Map.update(acc, why, 1, &(&1 + 1)))

    crashes = Enum.count(rs, &crash?/1)
    hangs = Enum.count(rs, &hang?/1)
    finds = Enum.map(rs, & &1.find_ms)
    ups = Enum.map(rs, & &1.up_ms)

    "#{label}: n=#{length(rs)} gps=#{Enum.count(rs, & &1.truth)} detected=#{Enum.count(rs, &(&1.truth and &1.detection == :agree))} missed=#{Enum.count(rs, &(&1.detection == :missed))} false_pos=#{Enum.count(rs, &(&1.detection == :false_positive))} accepted=#{Enum.count(rs, &(&1.outcome == :accepted))} refused=#{inspect(refused)} leaks=#{Enum.count(rs, &(&1.leaks != []))} crashes=#{crashes} hangs=#{hangs} | find #{median(finds)}/#{Enum.max(finds)} | upload #{median(ups)}/#{Enum.max(ups)}"
  end

  defp median(l) do
    s = Enum.sort(l)
    Enum.at(s, div(length(s), 2))
  end

  defp crash?(r), do: match?({:crash, _}, r.detection) or match?({:crash, _}, r.outcome)
  defp hang?(r), do: r.detection == :hang or r.outcome == :hang

  defp failures(rows) do
    Enum.flat_map(rows, fn r ->
      [
        r.leaks != [] && "#{r.rel}: stored file with GPS #{inspect(r.leaks)}",
        r.detection == :missed && "#{r.rel}: detection missed GPS that exiftool finds",
        crash?(r) && "#{r.rel}: crash #{inspect({r.detection, r.outcome})}",
        hang?(r) && "#{r.rel}: hang"
      ]
      |> Enum.filter(& &1)
    end)
  end
end
