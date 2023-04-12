defmodule Bonfire.Files.Routes do
  alias Bonfire.Common.Config

  defmacro __using__(_) do
    quote do
      # pages anyone can view
      scope "/" do
        pipe_through(:basic_html)

        get("/favicon_fetch", Bonfire.Files.Web.FaviconFetchController, as: :favicon_fetch)
      end
    end
  end
end
