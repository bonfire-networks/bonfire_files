# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.TestAcceptedTypes do
  @moduledoc "The upload types an instance accepts are built at boot from the tools it has (see `Bonfire.Files.MediaEdit.capabilities/0`), so a test machine without a tool lacks the types that need it. A test of what happens to such a file once it is accepted adds the type for its own process with `accept/2`."

  @doc "Adds `types` to what `uploader` accepts, in the calling process only."
  def accept(uploader, types) do
    Process.put(
      [:bonfire_files, uploader, :allowed_media_types],
      Enum.uniq(uploader.allowed_media_types() ++ List.wrap(types))
    )
  end

  @doc "Adds SVG to what each of `uploaders` accepts, in the calling process only."
  def accept_svg(uploaders), do: Enum.each(uploaders, &accept(&1, "image/svg+xml"))
end
