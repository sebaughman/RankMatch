defmodule QueueOfMatchmaking.Web.Router do
  @moduledoc """
  Plug router for GraphQL endpoints.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/graphql",
    to: Absinthe.Plug,
    init_opts: [schema: QueueOfMatchmaking.Graphql.Schema]
  )

  if Mix.env() == :dev do
    forward("/graphiql",
      to: Absinthe.Plug.GraphiQL,
      init_opts: [
        schema: QueueOfMatchmaking.Graphql.Schema,
        interface: :playground,
        socket: QueueOfMatchmaking.Web.Socket
      ]
    )
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
