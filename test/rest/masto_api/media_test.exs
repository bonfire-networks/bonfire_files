# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MastoApi.MediaTest do
  use Bonfire.Files.MastoApiCase, async: true

  import Bonfire.Files.Simulation
  alias Bonfire.Me.Fake

  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  @moduletag :masto_api

  describe "POST /api/v1/media" do
    test "uploads a file and returns MediaAttachment format", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      # Create a Plug.Upload struct from our test file
      file = image_file()

      upload = %Plug.Upload{
        path: file.path,
        filename: file.filename,
        content_type: "image/png"
      }

      api_conn =
        conn
        |> masto_api_conn(user: user, account: account)
        |> put_req_header("content-type", "multipart/form-data")

      response =
        api_conn
        |> post("/api/v1/media", %{"file" => upload, "description" => "Test image"})
        |> json_response(200)

      # Validate MediaAttachment structure - required fields
      assert is_binary(response["id"])
      assert response["type"] in ["image", "gifv", "video", "audio", "unknown"]
      assert is_binary(response["url"])
      assert is_binary(response["preview_url"])
      assert response["description"] == "Test image"

      # meta should be present (at least as empty map)
      assert is_map(response["meta"])
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      file = image_file()

      upload = %Plug.Upload{
        path: file.path,
        filename: file.filename,
        content_type: "image/png"
      }

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "multipart/form-data")
        |> post("/api/v1/media", %{"file" => upload})
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns error when no file provided", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/media", %{})
        |> json_response(400)

      assert response["error"]
    end
  end

  describe "GET /api/v1/media/:id" do
    test "returns MediaAttachment for owned media", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      # Create a media attachment first
      {:ok, media} = Files.upload(ImageUploader, user, image_file(), %{})

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/media/#{media.id}")
        |> json_response(200)

      assert response["id"] == media.id
      assert response["type"] == "image"
      assert is_binary(response["url"])
    end

    test "returns 404 for non-existent media", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/media/01KFKNQ2NV1673CZGRRHAAMDR5")
        |> json_response(404)

      assert response["error"]
    end

    test "returns 404 for media owned by another user", %{conn: conn} do
      owner = Fake.fake_user!()
      other_account = Fake.fake_account!()
      other_user = Fake.fake_user!(other_account)

      # Create media as owner
      {:ok, media} = Files.upload(ImageUploader, owner, image_file(), %{})

      # Try to access as other_user
      api_conn = masto_api_conn(conn, user: other_user, account: other_account)

      response =
        api_conn
        |> get("/api/v1/media/#{media.id}")
        |> json_response(404)

      assert response["error"]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      owner = Fake.fake_user!()
      {:ok, media} = Files.upload(ImageUploader, owner, image_file(), %{})

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/media/#{media.id}")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "PUT /api/v1/media/:id" do
    test "updates description and returns updated MediaAttachment", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, media} = Files.upload(ImageUploader, user, image_file(), %{})

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> put("/api/v1/media/#{media.id}", %{"description" => "Updated description"})
        |> json_response(200)

      assert response["id"] == media.id
      assert response["description"] == "Updated description"
    end

    test "updates focus point", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, media} = Files.upload(ImageUploader, user, image_file(), %{})

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> put("/api/v1/media/#{media.id}", %{"focus" => "0.5,-0.3"})
        |> json_response(200)

      assert response["id"] == media.id
      # Focus should be stored in meta
      assert is_map(response["meta"])
    end

    test "returns 404 for media owned by another user", %{conn: conn} do
      owner = Fake.fake_user!()
      other_account = Fake.fake_account!()
      other_user = Fake.fake_user!(other_account)

      {:ok, media} = Files.upload(ImageUploader, owner, image_file(), %{})

      api_conn = masto_api_conn(conn, user: other_user, account: other_account)

      response =
        api_conn
        |> put("/api/v1/media/#{media.id}", %{"description" => "Hacked!"})
        |> json_response(404)

      assert response["error"]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      owner = Fake.fake_user!()
      {:ok, media} = Files.upload(ImageUploader, owner, image_file(), %{})

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/media/#{media.id}", Jason.encode!(%{"description" => "test"}))
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "POST /api/v2/media" do
    test "uploads a file (same as v1 for now)", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      file = image_file()

      upload = %Plug.Upload{
        path: file.path,
        filename: file.filename,
        content_type: "image/png"
      }

      api_conn =
        conn
        |> masto_api_conn(user: user, account: account)
        |> put_req_header("content-type", "multipart/form-data")

      response =
        api_conn
        |> post("/api/v2/media", %{"file" => upload, "description" => "V2 upload"})
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["type"] in ["image", "gifv", "video", "audio", "unknown"]
      assert response["description"] == "V2 upload"
    end
  end
end
