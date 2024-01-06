defmodule Bonfire.Files.DOI do
  alias Furlex.Fetcher

  def fetch(url) do
    # with true <- is_doi?(url),
    with {:ok, body, 200} <- Fetcher.fetch("https://api.crossref.org/works/#{url}"),
         {:ok, %{"message" => data}} <- Jason.decode(body) do
      with %{"link" => links} when is_list(links) <- data do
        Enum.find_value(links, fn
          %{"content-type" => "application/pdf", "URL" => link} ->
            {:ok, Map.put(data, :download_url, link)}

          _ ->
            false
        end)
      end || {:ok, data}
    end
  end

  def is_doi?("doi:" <> _), do: true
  def is_doi?("https://doi.org" <> _), do: true
  def is_doi?("http://doi.org" <> _), do: true

  def is_doi?(url),
    do:
      is_binary(url) and
        (String.match?(url, ~r/\bdoi\.org\b/i) or
           String.match?(url, ~r/^10.\d{4,9}\/[-._;()\/:A-Z0-9]+$/i))
end
