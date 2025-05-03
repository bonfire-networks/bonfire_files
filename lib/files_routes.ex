defmodule Bonfire.Files.Routes do
  @behaviour Bonfire.UI.Common.RoutesModule
  use Bonfire.Common.Config

  defmacro __using__(_) do
    quote do
      # pages anyone can view
      scope "/" do
        pipe_through(:basic_html)

        get("/favicon_fetch", Bonfire.Files.Web.FaviconFetchController, as: :favicon_fetch)

        pipe_through(:browser)

        live("/media", Bonfire.UI.Files.Web.MediaFeedLive, :all, as: :media_feed)
        live("/links", Bonfire.UI.Files.Web.MediaFeedLive, :links, as: :links_feed)
      end
    end
  end
end
