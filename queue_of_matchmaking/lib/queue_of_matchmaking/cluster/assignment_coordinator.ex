defmodule QueueOfMatchmaking.Cluster.AssignmentCoordinator do
  @moduledoc """
  Centralized coordinator for partition assignment snapshots.
  Provides single source of truth for assignment state across the cluster.

  TODO: Later becomes Horde-managed singleton for HA.
  TODO: Multi-epoch operation (warm-up, cutover, cleanup).
  TODO: Automatic refresh on membership changes.
  TODO: State machine for cutover orchestration.
  """

  use GenServer
  require Logger

  alias QueueOfMatchmaking.Cluster.Assignment
  alias QueueOfMatchmaking.Config

  @pubsub QueueOfMatchmaking.PubSub
  @topic "assignments"

  # Client API

  @doc """
  Starts the AssignmentCoordinator.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current epoch.
  """
  def current_epoch do
    GenServer.call(__MODULE__, :current_epoch)
  end

  @doc """
  Returns the full assignment snapshot.
  """
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Returns the list of assignments.
  """
  def assignments do
    GenServer.call(__MODULE__, :assignments)
  end

  @doc """
  Returns the partitioning spec.
  """
  def spec do
    GenServer.call(__MODULE__, :spec)
  end

  @doc """
  Returns the sorted node list.
  """
  def nodes do
    GenServer.call(__MODULE__, :nodes)
  end

  @doc """
  Rebuilds the assignment snapshot.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc """
  Subscribes to assignment update events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    snapshot = build_snapshot()

    # Broadcast update for Router and other subscribers
    broadcast_update(snapshot)

    {:ok, %{snapshot: snapshot}}
  end

  @impl true
  def handle_call(:current_epoch, _from, state) do
    {:reply, state.snapshot.epoch, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_call(:assignments, _from, state) do
    {:reply, state.snapshot.assignments, state}
  end

  @impl true
  def handle_call(:spec, _from, state) do
    {:reply, state.snapshot.spec, state}
  end

  @impl true
  def handle_call(:nodes, _from, state) do
    {:reply, state.snapshot.nodes, state}
  end

  @impl true
  def handle_call(:refresh, _from, _state) do
    snapshot = build_snapshot()
    broadcast_update(snapshot)
    {:reply, :ok, %{snapshot: snapshot}}
  end

  # Private Helpers

  defp build_snapshot do
    config = Config.cluster_config()
    nodes = get_sorted_nodes()

    if nodes == [] do
      Logger.warning("AssignmentCoordinator: No nodes available for assignment computation")
    end

    assignments = Assignment.compute_assignments(nodes, config)

    %{
      epoch: Keyword.fetch!(config, :epoch),
      spec: %{
        rank_min: Keyword.fetch!(config, :rank_min),
        rank_max: Keyword.fetch!(config, :rank_max),
        partition_count: Keyword.fetch!(config, :partition_count)
      },
      nodes: nodes,
      assignments: assignments,
      computed_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp get_sorted_nodes do
    [node() | Node.list()]
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp broadcast_update(snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:assignments_updated, snapshot})
  end
end
