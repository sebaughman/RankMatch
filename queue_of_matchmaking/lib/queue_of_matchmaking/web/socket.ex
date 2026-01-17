defmodule QueueOfMatchmaking.Web.Socket do
  @moduledoc """
  Phoenix socket for Absinthe GraphQL subscriptions.
  """

  use Phoenix.Socket
  use Absinthe.Phoenix.Socket, schema: QueueOfMatchmaking.Graphql.Schema

  def connect(_params, socket, _connect_info) do
    socket =
      Absinthe.Phoenix.Socket.put_options(socket,
        schema: QueueOfMatchmaking.Graphql.Schema,
        context: %{pubsub: QueueOfMatchmaking.Web.Endpoint}
      )

    {:ok, socket}
  end

  def id(_socket), do: nil
end
