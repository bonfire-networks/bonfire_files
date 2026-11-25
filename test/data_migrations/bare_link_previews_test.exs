defmodule Bonfire.Files.DataMigrations.BareLinkPreviewsTest do
  @moduledoc """
  The link previews saved with nothing to show before 24 November are removed, with what they're attached to: a fetch that failed (an error status, or a page with no title, description, image or embed), and a federated `Link` named with its own URL (Gancio names an online event's link that way), which skipped our fetch and showed the URL as its title. Media of other kinds, and previews with something to show, are kept.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Files.DataMigrations.BareLinkPreviews
  alias Bonfire.Files.Media

  # each saved the way it was before the fix, with the metadata seen on prod or in what the fetch saved: `:federated` as `Bonfire.Files.ap_receive_attachments/3` saves an attachment it doesn't unfurl, `:unfurled` as `Media.maybe_save/4` saves a fetched preview
  @bare [
    gancio_link:
      {:federated, "https://youtube.com/live/FNqRMKlybO8", "text/html",
       %{"label" => "https://youtube.com/live/FNqRMKlybO8", "source_type" => "activitypub"}},
    # an unnamed `Link` our unfurl found nothing for, saved as the bare link (Akkoma's stats images on libera.site)
    unnamed_link:
      {:federated, "https://libera.local/_stats/akkoma/statuses.png", "Link",
       %{"source_type" => "activitypub"}},
    empty_page:
      {:unfurled, "https://example.com/empty", "link",
       %{status_code: 200, content_type: "text/html"}},
    error_page:
      {:unfurled, "https://example.com/denied", "link",
       %{status_code: 403, content_type: "text/html", other: %{"title" => "Access denied"}}},
    bot_wall:
      {:unfurled, "https://example.com/guarded", "link",
       %{status_code: 200, content_type: "text/html", other: %{"title" => "Just a moment..."}}},
    # a quote's FEP-e232 `tag` Link, saved as an attachment before quote Links were recognised (Bridgy Fed sends no quote `rel`); the post's text has the link
    bridgy_quote_link:
      {:federated, "https://bsky.brid.local/convert/ap/at://did:plc:a/app.bsky.feed.post/b",
       ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams"),
       %{"source_type" => "activitypub"}},
    # named as Mastodon and Friendica name a quote's Link, which shows nothing but the URL (6,020 of 6,179 such links on bonfire.cafe)
    re_named_quote_link:
      {:federated, "https://social.example.local/objects/2",
       ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams"),
       %{"label" => "RE: https://social.example.local/objects/2", "source_type" => "activitypub"}},
    unsourced_quote_link:
      {:federated, "https://apgateway.local/.well-known/apgateway/did:key:z/item/1",
       "application/activity+json", %{}}
  ]

  @kept [
    real_preview:
      {:unfurled, "https://example.com/article", "article",
       %{status_code: 200, facebook: %{"title" => "An article"}}},
    remote_avatar:
      {:federated, "https://files.mastodon.local/accounts/avatars/1/original/a.png", nil, %{}},
    named_link:
      {:federated, "https://example.com/stream", "text/html",
       %{"label" => "Watch the stream", "source_type" => "activitypub"}},
    named_quote_link:
      {:federated, "https://social.example.local/objects/1",
       ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams"),
       %{"label" => "A post about cats", "source_type" => "activitypub"}}
  ]

  defp save(user, :federated, url, media_type, metadata) do
    Bonfire.Files.save_url_as_media(
      user,
      url,
      %{media_type: media_type, client_name: url, metadata: metadata},
      if(media_type, do: Bonfire.Files.DocumentUploader)
    )
  end

  defp save(user, :unfurled, url, media_type, metadata) do
    Media.insert(user, url, %{id: nil, media_type: media_type, size: 0}, %{
      url: url,
      media_type: media_type,
      metadata: metadata
    })
  end

  setup do
    user = fake_user!()

    media =
      Map.new(@bare ++ @kept, fn {name, {how, url, media_type, metadata}} ->
        {:ok, media} = save(user, how, url, media_type, metadata)
        # attached to something, as a preview is to its post
        repo().insert!(%Bonfire.Files{id: fake_user!().id, media_id: media.id})
        {name, media.id}
      end)

    %{media: media}
  end

  defp exists?(id), do: repo().exists?(from(m in Media, where: m.id == ^id))
  defp attached?(id), do: repo().exists?(from(f in Bonfire.Files, where: f.media_id == ^id))

  defp run, do: BareLinkPreviews.base_query() |> repo().all() |> BareLinkPreviews.migrate()

  test "removes the link previews with nothing to show, and keeps the others", %{media: media} do
    for {name, id} <- media do
      assert exists?(id) and attached?(id), "control: #{name} is there, attached"
    end

    selected = BareLinkPreviews.base_query() |> repo().all() |> Map.new(&{&1.id, &1.metadata})

    for {name, _} <- @bare do
      assert is_map(selected[media[name]]), "#{name} should be selected, with its metadata"

      refute Media.preview_worth_saving?(selected[media[name]]),
             "#{name} should have nothing to show: #{inspect(selected[media[name]])}"
    end

    # not even read: the query sends no metadata for what has something to show
    for {name, _} <- @kept do
      assert is_nil(selected[media[name]]), "#{name}'s metadata should not be sent"
    end

    run()

    for {name, _} <- @bare do
      refute exists?(media[name]), "#{name} should be removed"
      refute attached?(media[name]), "#{name}'s attachment should be removed"
    end

    for {name, _} <- @kept do
      assert exists?(media[name]), "#{name} should be kept"
      assert attached?(media[name]), "#{name}'s attachment should be kept"
    end
  end
end
