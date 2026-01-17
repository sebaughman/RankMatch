defmodule QueueOfMatchmaking.Application do
  @moduledoc """
  OTP application for distributed matchmaking system.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: QueueOfMatchmaking.PubSub},
      QueueOfMatchmaking.Horde.Registry,
      QueueOfMatchmaking.Horde.Supervisor,
      QueueOfMatchmaking.Cluster.AssignmentCoordinator,
      QueueOfMatchmaking.Cluster.Membership,
      QueueOfMatchmaking.Index.UserIndex,
      QueueOfMatchmaking.Cluster.PartitionManager,
      QueueOfMatchmaking.Cluster.Router,
      QueueOfMatchmaking.Web.Endpoint,
      {Absinthe.Subscription, QueueOfMatchmaking.Web.Endpoint}
    ]

    opts = [strategy: :one_for_one, name: QueueOfMatchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
