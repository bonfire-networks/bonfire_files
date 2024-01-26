defmodule Bonfire.Files.DOI do
  alias Furlex.Fetcher
  import Untangle

  @doi_matcher "10.\d{4,9}\/[-._;()\/:A-Z0-9]+$"
  @pub_id_matchers %{
    pmid: ~r/[0-9]{1,8}/,
    pmcid: ~r/PMC[0-9]+/,
    # :doi => ~r/10.+\/.+/,
    doi: ~r/^#{@doi_matcher}/i,
    # doi_prefixed: ~r/doi:^#{@doi_matcher}/i
    doi_prefixed: ~r/^doi:([^\s]+)/i
    # scopus_eid: ~r/2-s2.0-[0-9]{11}/
  }
  @pub_uri_matchers %{
    doi_url: ~r/doi\.org([^\s]+)/i
  }
  @pub_id_and_uri_matchers Map.merge(@pub_id_matchers, @pub_uri_matchers)

  def maybe_fetch(url) do
    if is_pub_id_or_uri_match?(url), do: fetch(url)
  end

  def fetch(url) do
    url =
      "https://en.wikipedia.org/api/rest_v1/data/citation/wikibase/#{URI.encode_www_form(url)}"
      |> debug()

    # TODO: add a custom user agent 
    with {:ok, body, 200} <- Fetcher.fetch(url),
         {:ok, [data | _]} <- Jason.decode(body) do
      with %{"identifiers" => %{"url" => dl_url}} when dl_url != url <- data do
        key = if String.ends_with?(dl_url, ".pdf"), do: :download_url, else: :canonical_url

        {:ok,
         %{wikibase: data}
         |> Map.put(key, dl_url)}
      else
        _ ->
          {:ok, %{wikibase: data}}
      end
    else
      e ->
        warn(e, "Could not find data on wikipedia, try another source...")
        fetch_crossref(url)
    end
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

  def pub_id_matchers(), do: @pub_id_matchers
  def pub_uri_matchers(), do: @pub_uri_matchers
  def pub_id_and_uri_matchers(), do: @pub_id_and_uri_matchers
  def pub_id_matcher(type), do: pub_id_and_uri_matchers()[type]
end
