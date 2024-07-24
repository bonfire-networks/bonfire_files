# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.FileDenied do
  import Untangle
  alias Sizeable
  use Bonfire.Common.Localise

  @enforce_keys [:message, :code, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          message: binary,
          code: binary,
          status: integer
        }

  def new(size) when is_number(size) do
    %__MODULE__{
      message: l("This file exceeds the maximum upload size of %{size}", size: Sizeable.filesize(size)),
      code: "file_denied",
      status: 415
    }
  end

  def new(mime_type) when is_binary(mime_type) do
    %__MODULE__{
      message: l("Files with the format of %{type} are not allowed", type: mime_type),
      code: "file_denied",
      status: 415
    }
  end

  def new(other) do
    warn(other, "unknown mime or size")

    %__MODULE__{
      message: l("Files with an unrecognised format or size are not allowed"),
      code: "file_denied",
      status: 415
    }
  end
end
