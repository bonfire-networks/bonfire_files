defmodule Bonfire.UI.Files.Web.MediaFeedLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  declare_nav_link(l("Media"),
    page: "media",
    href: "/media",
    icon: "carbon:image"
    # icon: "carbon:document"
  )

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       # the local instance's media, one tile per file: the `local_media` preset, without link previews (`"attachment"`), which aren't media of their own
       feed_name: :local_media,
       feed_filters: %{media_types: ["attachment"]},
       page_title: l("Media")
     )}
  end

  # def handle_params(%{"tab" => tab} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      selected_tab: tab
  #    )}
  # end

  # def handle_params(%{} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      current_user: Fake.user_live()
  #    )}
  # end
end
