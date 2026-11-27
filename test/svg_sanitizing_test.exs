# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.SvgSanitizingTest do
  @moduledoc """
  Every SVG upload (post images, emoji, instance icons) goes through `MediaEdit.sanitize_svg/0`.

  The first part runs wherever the tests run: what happens when `SvgSanitizer` (a precompiled Linux NIF, only in prod builds) is absent, with a stand-in module for the wiring. The second part (`:svg_sanitizer`) runs only where the real module is compiled in, and is skipped otherwise.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.{EmojiUploader, ImageUploader, InstanceIconUploader}

  @fixtures Path.expand("fixtures/svg", __DIR__)
  @uploaders [ImageUploader, EmojiUploader, InstanceIconUploader]

  defmodule StandIn do
    @moduledoc false
    def sanitize(_svg),
      do: {:ok, ~s|<svg xmlns="http://www.w3.org/2000/svg"><!--stand-in--></svg>|}
  end

  defmodule Failing do
    @moduledoc false
    def sanitize(_svg), do: {:error, :parse_error}
  end

  defp use_sanitizer(value),
    do: Process.put([:bonfire_files, :choose_executable, SvgSanitizer], value)

  defp use_env(env), do: Process.put([:bonfire_files, :env], env)

  # the per-upload refusals under test are the safety net behind the accepted types, which leave SVG out where the sanitiser is missing
  setup do
    Bonfire.Files.TestAcceptedTypes.accept_svg(@uploaders)
    :ok
  end

  defp upload(uploader, creator, fixture) do
    Files.upload(uploader, creator, %{path: Path.join(@fixtures, fixture), filename: fixture})
  end

  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*") |> Enum.filter(&File.regular?/1)
  end

  describe "without the sanitiser" do
    setup do
      use_sanitizer(false)
      :ok
    end

    for env <- [:test, :prod], uploader <- @uploaders do
      test "#{inspect(uploader)} refuses an SVG in #{env}, with a message" do
        use_env(unquote(env))
        creator = fake_user!()

        assert {:error, %Bonfire.Fail{code: :svg_sanitiser_unavailable, message: message}} =
                 upload(unquote(uploader), creator, "normal.svg")

        assert message =~ "SVG"
        assert stored_files(creator) == []
      end
    end

    for uploader <- @uploaders do
      test "#{inspect(uploader)} stores an SVG as it is in dev" do
        use_env(:dev)
        creator = fake_user!()

        assert {:ok, _} = upload(unquote(uploader), creator, "malicious.svg")

        assert [stored] = stored_files(creator)
        assert File.read!(stored) == File.read!(Path.join(@fixtures, "malicious.svg"))
      end
    end
  end

  describe "with a sanitiser" do
    for uploader <- @uploaders do
      test "#{inspect(uploader)} stores what the sanitiser returns" do
        use_sanitizer(StandIn)
        use_env(:prod)
        creator = fake_user!()

        assert {:ok, _} = upload(unquote(uploader), creator, "malicious.svg")

        assert [stored] = stored_files(creator)
        assert File.read!(stored) =~ "stand-in"
        refute File.read!(stored) =~ "script"
      end

      test "#{inspect(uploader)} refuses an SVG the sanitiser can't handle, in every env" do
        use_sanitizer(Failing)

        for env <- [:dev, :test, :prod] do
          use_env(env)
          creator = fake_user!()

          assert {:error, %Bonfire.Fail{code: :svg_unsanitisable, message: message}} =
                   upload(unquote(uploader), creator, "malicious.svg")

          assert message =~ "SVG"
          assert stored_files(creator) == []
        end
      end
    end
  end

  # NOT run where `SvgSanitizer` isn't compiled in (macOS dev machines, and test unless its dep line includes `:test`)
  describe "with the real SvgSanitizer" do
    @describetag :svg_sanitizer
    @describetag skip:
                   if(Code.ensure_loaded?(SvgSanitizer),
                     do: false,
                     else: "SvgSanitizer is not compiled in this environment"
                   )

    defp stored_svg(uploader, fixture) do
      creator = fake_user!()
      assert {:ok, _} = upload(uploader, creator, fixture)
      assert [stored] = stored_files(creator)
      File.read!(stored)
    end

    for uploader <- @uploaders do
      test "#{inspect(uploader)} removes everything that runs or loads" do
        svg = stored_svg(unquote(uploader), "malicious.svg")

        for needle <-
              ~w(script-element onload-attr onclick-attr foreign-object-html foreignObject evil.example javascript) do
          refute svg =~ needle, "#{needle} is still in: #{svg}"
        end
      end

      test "#{inspect(uploader)} keeps a normal SVG's viewBox, gradient, defs and internal references" do
        svg = stored_svg(unquote(uploader), "normal.svg")

        assert svg =~ "viewBox"
        assert svg =~ "linearGradient"
        assert svg =~ "<defs"
        assert svg =~ "url(#grad)"
        assert svg =~ ~r/href="#dot"/
      end

      test "#{inspect(uploader)} drops the metadata (and so the location) of an SVG" do
        svg = stored_svg(unquote(uploader), "../gps/gps.svg")

        refute svg =~ "GPSLatitude"
        refute svg =~ "metadata"
      end
    end

    test "an external entity is removed or the SVG refused, never expanded" do
      creator = fake_user!()

      case upload(ImageUploader, creator, "xxe.svg") do
        {:ok, _} ->
          for f <- stored_files(creator), do: refute(File.read!(f) =~ "root:")

        {:error, %Bonfire.Fail{code: :svg_unsanitisable}} ->
          assert stored_files(creator) == []
      end
    end

    test "the favicon store sanitises a remote SVG" do
      assert {:ok, clean} =
               Bonfire.Files.MediaEdit.sanitize_svg_binary(
                 File.read!(Path.join(@fixtures, "malicious.svg"))
               )

      refute clean =~ "script-element"
    end
  end
end
