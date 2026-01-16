defmodule QueueOfMatchmaking.Web.Endpoint do
  @moduledoc """
  Phoenix endpoint for HTTP and WebSocket connections.
  """

  use Phoenix.Endpoint, otp_app: :queue_of_matchmaking

  socket("/socket", QueueOfMatchmaking.Web.Socket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(QueueOfMatchmaking.Web.Router)
end
