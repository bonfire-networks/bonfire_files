defmodule Bonfire.Files.Routes do
  @behaviour Bonfire.UI.Common.RoutesModule
  use Bonfire.Common.Config

  defmacro __using__(_) do
    quote do
      # pages anyone can view
      scope "/" do
        pipe_through(:basic)

        get("/files/favicon", Bonfire.Files.Web.FaviconFetchController, as: :favicon_fetch)

        get(
          "/files/redir/f/:target/:storage/data/uploads/:creator/:type/*path",
          Bonfire.Files.Web.UploadRedirectController,
          as: :upload_redirect
        )

        get("/files/redir/f/:target/:storage/*path", Bonfire.Files.Web.UploadRedirectController,
          as: :upload_redirect
        )

        get("/files/redir/:storage/*path", Bonfire.Files.Web.UploadRedirectController,
          as: :upload_redirect
        )

        pipe_through(:browser)

        live("/media", Bonfire.UI.Files.Web.MediaFeedLive, :all, as: :media_feed)
        live("/links", Bonfire.UI.Files.Web.MediaFeedLive, :links, as: :links_feed)
      end
    end
  end
end
