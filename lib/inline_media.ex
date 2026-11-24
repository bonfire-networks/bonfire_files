defmodule Bonfire.Files.InlineMedia do
  @moduledoc """
  Media an author places in an object's body, rather than only attaching it.

  An image is placed with `![](url)`, and a player (or an image) with its bare URL alone on a line, where `url` is the media's `Bonfire.Files.inline_url/1`. The media is still attached to the object, for boundaries and federation. It's found by comparing its URL with the body, so it can be left out of the attachment list and rendered where it sits (see `Bonfire.Common.Text.markdown_parts/3`).
  """
  use Bonfire.Common.E
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Text
  alias Bonfire.Files

  @doc """
  The ids of the media in `media_list` that `body` places inline: the media's URL is alone in a paragraph, or is the source of an image anywhere in the body (an image shows once, wherever it sits). A link to it in the middle of a sentence isn't.
  """
  def inline_ids(body, media_list) when is_binary(body) and body != "" do
    case List.wrap(media_list) do
      [] ->
        []

      media_list ->
        placed =
          (Text.standalone_urls(body) ++ Text.image_urls(body))
          |> MapSet.new(&absolute_url/1)

        for media <- media_list,
            url = Files.inline_url(media),
            MapSet.member?(placed, url),
            do: Enums.id(media)
    end
  end

  def inline_ids(_, _), do: []

  @doc """
  Which of `media` (attachment rows or `Media`) `body` places, so they're left out of the attachment list and rendered where they sit: any whose URL is in the body, a file or a link alike. A link in a sentence then has no card (until links get previews on hover).

  Only compares URLs, with no parse and no query: cheap enough to run on every render.
  """
  def placed(media, body) when is_binary(body) and body != "" do
    for m <- List.wrap(media), in_body?(m, body), do: m
  end

  def placed(_, _), do: []

  @doc "The media `body` places (see `placed/2`) by each URL a body can have for it (absolute, and as a local path), for rendering each where it sits."
  def url_map(media, body) do
    for m <- placed(media, body),
        media = e_media(m),
        url = Files.inline_url(media),
        key <- url_forms(url),
        into: %{},
        do: {key, media}
  end

  @doc "The attached media of `activity` or `object`, the first that has any, in the same order `Bonfire.UI.Social.ActivityLive` reads them for its attachment list, and what `object`'s body places among them (see `url_map/2`)."
  def url_map_for(activity, object) do
    media =
      Enum.find_value(
        [
          e(activity, :files, nil),
          e(object, :files, nil),
          e(activity, :media, nil),
          e(object, :media, nil)
        ],
        &Enums.filter_empty(&1, nil)
      )

    url_map(media, e(object, :post_content, :html_body, nil))
  end

  @doc """
  One pass over `media` (attachment rows or `Media`) and the `body` they're attached with, by where the body is actually cut, for rendering each placed media where it sits and listing the rest:

  - `parts`: the body cut at each media URL that ends a line (`Bonfire.Common.Text.markdown_parts/3`, and `html_parts/3` for an HTML body, with `opts` as the body is rendered), or nil when no media URL is in the body at all, so it isn't parsed.
  - `inline_media`: the media the body places, by each URL a body can have for it (as `url_map/2`): each one it's cut at, and each image it shows by its source wherever it sits, since that image shows once.
  - `unplaced`: the rest of `media`, for the attachment list. A link in the middle of a sentence isn't cut, so its card stays in the list.

  Each media's URLs are computed once, and the cheap string check of `placed/2` only decides whether the body is cut at all.
  """
  def split(media, body, opts \\ [])

  def split(media, body, opts) when is_binary(body) and body != "" do
    media = List.wrap(media)

    candidates =
      for m <- media,
          url = Files.inline_url(e_media(m)),
          is_binary(url),
          forms = url_forms(url),
          forms_in_body?(forms, body),
          do: {m, forms}

    case candidates do
      [] ->
        %{parts: nil, inline_media: %{}, unplaced: media}

      candidates ->
        by_form = for {m, forms} <- candidates, form <- forms, into: %{}, do: {form, m}
        parts = Text.markdown_parts(body, Map.keys(by_form), opts)

        images = Text.image_urls(body)
        shown = for({:url, url} <- parts, do: url) ++ images ++ Enum.map(images, &absolute_url/1)

        placed = for url <- shown, m = by_form[url], uniq: true, do: m

        %{
          parts: parts,
          inline_media:
            for(
              {m, forms} <- candidates,
              m in placed,
              form <- forms,
              into: %{},
              do: {form, e_media(m)}
            ),
          unplaced: Enum.reject(media, &(&1 in placed))
        }
    end
  end

  def split(media, _body, _opts),
    do: %{parts: nil, inline_media: %{}, unplaced: List.wrap(media)}

  # an HTML body (a remote one, an import) places its media where it shows it as an image, or links to it (as a URL in a local body does): `Bonfire.Common.Text.html_parts/3` cuts it there, and the `&` in a URL is stored as `&amp;`
  defp in_body?(m, body) do
    case Files.inline_url(e_media(m)) do
      url when is_binary(url) -> forms_in_body?(url_forms(url), body)
      _ -> false
    end
  end

  defp forms_in_body?(forms, "<" <> _ = html) do
    attributes =
      for form <- forms,
          form <- Enum.uniq([form, String.replace(form, "&", "&amp;")]),
          attr <- ["src", "href"],
          do: ~s(#{attr}="#{form}")

    String.contains?(html, attributes)
  end

  defp forms_in_body?(forms, body), do: String.contains?(body, forms)

  defp e_media(%{media: %Files.Media{} = media}), do: media
  defp e_media(media), do: media

  # a body stores our own links as paths (see `absolute_url/1`)
  defp url_forms(url) do
    Enum.uniq([url, String.replace_prefix(url, Bonfire.Common.URIs.base_url(), "")])
  end

  @doc """
  The composer places a file it hasn't uploaded yet as `![](upload:<ref>)`, `<ref>` being its upload entry's. At publish, once the files are stored, each becomes the image of the stored media in `media_by_ref` (`{ref, media}` pairs, or a map), at its `Bonfire.Files.inline_url/1`. The image of a ref with no stored media (its file was removed before publishing) is dropped.
  """
  def swap_upload_refs(body, media_by_ref) when is_binary(body) do
    media_by_ref = Map.new(media_by_ref)

    if String.contains?(body, "upload:") do
      Regex.replace(~r/!\[[^\]]*\]\(upload:([^)\s]+)\)/, body, fn image, ref ->
        case media_by_ref[ref] && Files.inline_url(media_by_ref[ref]) do
          url when is_binary(url) -> String.replace(image, "upload:" <> ref, url)
          _ -> ""
        end
      end)
    else
      body
    end
  end

  def swap_upload_refs(body, _), do: body

  @doc """
  Turns each player in `html` (`<iframe>`, `<video>`, `<audio>`, with a `src` of their own or in a `<source>`) into a link to it, where it was, since the sanitiser drops players: the body keeps their place. Returns the HTML and the players' URLs, in order. Only web addresses: a `javascript:` or relative source leaves nothing, as before. Used for incoming remote bodies and by the WordPress import.
  """
  def embeds_as_links(html) when is_binary(html) and html != "" do
    if String.contains?(html, ["<iframe", "<video", "<audio"]) do
      {tree, urls} =
        html
        |> Text.as_html_tree()
        |> LazyHTML.Tree.postwalk([], fn
          {tag, attrs, children} = node, urls when tag in ["iframe", "video", "audio"] ->
            case player_url(attrs, children) do
              nil ->
                {node, urls}

              url ->
                text =
                  case List.keyfind(attrs, "title", 0) do
                    {"title", title} when title != "" -> title
                    _ -> url
                  end

                # just the link: a player is often already in a paragraph, and an HTML body isn't split, so it needs no paragraph of its own
                {{"a", [{"href", url}], [text]}, [url | urls]}
            end

          node, urls ->
            {node, urls}
        end)

      if urls == [],
        do: {html, []},
        else: {LazyHTML.Tree.to_html(tree), urls |> Enum.reverse() |> Enum.uniq()}
    else
      {html, []}
    end
  end

  def embeds_as_links(html), do: {html, []}

  defp player_url(attrs, children) do
    web_url(List.keyfind(attrs, "src", 0)) ||
      Enum.find_value(children, fn
        {"source", source_attrs, _} -> web_url(List.keyfind(source_attrs, "src", 0))
        _ -> nil
      end)
  end

  # only a web address: a protocol-relative one (`//www.youtube.com/…`) is https
  defp web_url({"src", "//" <> rest}), do: web_url({"src", "https://" <> rest})

  defp web_url({"src", url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        url

      _ ->
        nil
    end
  end

  defp web_url(_), do: nil

  @doc "A URL as `Bonfire.Files.inline_url/1` gives it: a body stores our own links as paths (`/files/redir/…`, see `Bonfire.Common.URIs.normalise_local_links`), so a path is made absolute against this instance."
  def absolute_url("/" <> _ = path), do: Bonfire.Common.URIs.base_url() <> path
  def absolute_url(url), do: url
end
