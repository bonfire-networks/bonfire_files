defmodule Bonfire.Files.DataMigrations.BareLinkPreviews do
  @moduledoc """
  Removes the link previews saved with nothing to show before 24 November, with their attachment rows, so the next post of each link fetches it again:

  - a fetch that failed: an error status, or a page with no title, description, image or embed. Its metadata has the `status_code` only an unfurl stores.
  - a federated `Link` attachment named with its own URL (Gancio names an online event's link that way), which skipped our fetch and showed the URL as its title. Its metadata has `source_type: "activitypub"`, and its `media_type` is a `Link`'s.

  - a federated `Link` attachment our unfurl found nothing for, saved as the bare link (eg. Akkoma's stats images on libera.site). Removing it removes that link from its post, if the post doesn't also have it in its text.

  What has something to show is decided by `Bonfire.Files.Media.preview_worth_saving?/1`, as for a new fetch. Other Media (eg. a remote avatar, `"remote"` with empty metadata) are never selected.

  Safe to re-run: a removed preview is no longer selected.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  alias Bonfire.Files.Media

  # The `WHERE` only picks the kinds of Media a preview is, which most link Media are, so each batch's scan of the id index stops after about `batch_size` rows. Narrowing it to the ones with nothing to show made a batch scan until it found that many, 6.5 s per batch on bonfire.cafe (24 November), with nothing to stop a sparse stretch passing the 15 s `statement_timeout`, which ends the run for good (the runner only survives a failing `migrate/2`).
  # The narrowing is in the `SELECT` instead: only a row that may have nothing to show comes back with its metadata, so the others cost no transfer or decoding. `migrate/2` then decides with `Media.preview_worth_saving?/1`; the SQL errs towards sending the metadata, so a row it lets through that has something to show is still kept.
  @impl DataMigration
  def base_query do
    from(m in Media,
      where:
        ilike(m.path, "http%") and is_nil(m.deleted_at) and
          (not is_nil(fragment("?->>'status_code'", m.metadata)) or
             (fragment("?->>'source_type'", m.metadata) == "activitypub" and
                m.media_type in ["text/html", "Link", "link"])),
      select: %{
        id: m.id,
        metadata:
          fragment(
            # an error status, or none of: a title (the way `Media.media_label/1` mostly finds one, other than just a URL or Cloudflare's "Just a moment..." page), or a key that `Media.description/1`, `Media.metadata_image_url/1` or the embeds read. `(http|https)` rather than `https?`: a `?` is a parameter to `fragment`
            "CASE WHEN coalesce(?->>'status_code' !~ '^2[0-9][0-9]$', false) OR NOT (coalesce(coalesce(?->>'label', ?->>'title', ?->'oembed'->>'title', ?->'facebook'->>'title', ?->'twitter'->>'title', ?->'other'->>'title') !~* '^\\s*((http|https)://[^/\\s]+\\S*|just a moment.*)\\s*$', false) OR jsonb_exists_any(?, array['description', 'image', 'icon', 'preview', 'module', 'json_ld', 'wikibase', 'crossref', 'atom', 'rss', 'orcid', 'zenodo']) OR jsonb_exists_any(coalesce(?->'facebook', '{}'::jsonb), array['description', 'image', 'video']) OR jsonb_exists_any(coalesce(?->'twitter', '{}'::jsonb), array['description', 'image', 'player']) OR jsonb_exists_any(coalesce(?->'oembed', '{}'::jsonb), array['thumbnail_url', 'html', 'abstract']) OR jsonb_exists_any(coalesce(?->'other', '{}'::jsonb), array['description', 'og:image', 'og:image:url', 'msapplication-TileImage', 'apple-touch-icon'])) THEN ? END",
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata,
            m.metadata
          )
      }
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      # in the background, so boot isn't blocked: on bonfire.cafe (24 November) 740,229 Media match `base_query/0`
      async: true,
      batch_size: 1_000,
      throttle_ms: 200,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(rows), do: migrate(rows, [])

  # `opts[:repo]` is the repo the migration runs on (the migration passes its own `repo/0`), else the normal one
  @impl DataMigration
  def migrate(rows, opts) do
    repo = Keyword.get(opts, :repo, Bonfire.Common.Repo)

    # a row with no metadata is one the query found something to show in
    case rows
         |> Enum.filter(&(is_map(&1.metadata) and not Media.preview_worth_saving?(&1.metadata)))
         |> Enum.map(& &1.id) do
      [] ->
        :ok

      ids ->
        repo.transaction(fn ->
          {attachments, _} = repo.delete_all(from(f in Bonfire.Files, where: f.media_id in ^ids))
          {media, _} = repo.delete_all(from(m in Media, where: m.id in ^ids))

          info(
            %{attachments: attachments, media: media},
            "Removed link previews with nothing to show"
          )
        end)
    end
  end
end
