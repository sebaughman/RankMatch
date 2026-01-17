defmodule QueueOfMatchmaking.Application do
  @moduledoc """
  OTP application for distributed matchmaking system.
  """

  use Application

  alias QueueOfMatchmaking.Config

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: QueueOfMatchmaking.PubSub},
      QueueOfMatchmaking.Horde.Registry,
      QueueOfMatchmaking.Horde.Supervisor,
      QueueOfMatchmaking.Index.UserIndex,
      {QueueOfMatchmaking.Matchmaking.PartitionWorker,
       epoch: 1,
       partition_id: "p-00000-10000",
       range_start: 0,
       range_end: 10_000,
       config: Config.matchmaking_config(),
       name: QueueOfMatchmaking.PartitionWorker.FullRange},
      QueueOfMatchmaking.Web.Endpoint,
      {Absinthe.Subscription, QueueOfMatchmaking.Web.Endpoint}
    ]

    opts = [strategy: :one_for_one, name: QueueOfMatchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
