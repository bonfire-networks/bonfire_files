defmodule Bonfire.Files.DOI do
  alias Unfurl.Fetcher
  alias Bonfire.Common.Utils
  alias Bonfire.Common.HTTP
  import Untangle

  def doi_matcher, do: "10.\d{4,9}\/[-._;()\/:A-Z0-9]+$"

  def pub_id_matchers,
    do: %{
      # :doi => ~r/10.+\/.+/,
      doi: ~r/^#{doi_matcher()}/i,
      # doi_prefixed: ~r/doi:^#{doi_matcher()}/i
      doi_prefixed: ~r/^doi:([^\s]+)/i
    }

  def pub_uri_matchers,
    do: %{
      doi_url: ~r/doi\.org([^\s]+)/i
    }

  def pub_id_and_uri_matchers, do: Map.merge(pub_id_matchers(), pub_uri_matchers())

  def pub_id_matcher(type), do: pub_id_and_uri_matchers()[type]

  def maybe_fetch(url) do
    if is_pub_id_or_uri_match?(url), do: fetch(url)
  end

  def fetch(url, _opts \\ []) do
    # use the function from the extension if available, as it may be more up-to-date or full-featured
    Utils.maybe_apply(Bonfire.OpenScience.APIs, :fetch_crossref, url,
      fallback_fun: fn -> fetch_crossref(url) end
    )
  end

  def fetch_crossref(url) do
    with true <- is_doi?(url),
         # TODO: add a custom user agent or optional API key?
         {:ok, body, 200} <-
           Fetcher.fetch("https://api.crossref.org/works/#{URI.encode_www_form(url)}"),
         {:ok, %{"message" => data}} <- Jason.decode(body) do
      with %{"link" => links} when is_list(links) <- data do
        Enum.find_value(links, fn
          %{"content-type" => "application/pdf", "URL" => dl_url} when dl_url != url ->
            {:ok, %{crossref: data, download_url: dl_url}}

          _ ->
            nil
        end)
      end || {:ok, %{crossref: data}}
    end
  end

  def is_doi?("doi:" <> _), do: true
  def is_doi?("https://doi.org/" <> _), do: true
  def is_doi?("http://doi.org/" <> _), do: true

  def is_doi?(url),
    do:
      is_binary(url) and
        (String.match?(url, pub_id_matcher(:doi)) ||
           String.match?(url, pub_id_matcher(:doi_prefixed)))

  def is_pub_id_or_uri_match?(url) do
    pub_id_and_uri_matchers()
    |> Map.values()
    |> Enum.any?(fn
      fun when is_function(fun, 1) ->
        fun.(url)
        |> debug(url)

      scheme ->
        String.match?(url, scheme)
    end)
  end
end
