# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.CorruptedUploadTest do
  @moduledoc """
  A file whose transformation fails (a JPEG with garbled scan data) is refused with a `%Bonfire.Fail{}` whose message names the file, never a raw `%Task{}`, and nothing is stored.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  @fixtures Path.expand("fixtures", __DIR__)

  test "a corrupted JPEG is refused with a readable error naming the file, and nothing is stored" do
    creator = fake_user!()
    path = Path.join(@fixtures, "corrupted/corrupted.jpg")

    result =
      Files.upload(ImageUploader, creator, %{path: path, filename: "holiday.jpg"}, %{
        client_name: "holiday.jpg"
      })

    assert {:error, %Bonfire.Fail{message: message}} = result
    assert message =~ "Could not process"
    assert message =~ "holiday.jpg"
    assert stored_files(creator) == []
  end

  test "control: a valid JPEG uploads" do
    creator = fake_user!()
    path = Path.join(@fixtures, "tn_150.jpg")

    assert {:ok, _} =
             Files.upload(ImageUploader, creator, %{path: path, filename: "tn_150.jpg"}, %{})

    assert stored_files(creator) != []
  end

  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*")
    |> Enum.filter(&File.regular?/1)
  end
end
