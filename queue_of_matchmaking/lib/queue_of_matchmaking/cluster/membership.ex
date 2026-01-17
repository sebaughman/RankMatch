defmodule QueueOfMatchmaking.Cluster.Membership do
  @moduledoc """
  Monitors cluster membership and propagates node changes.

  On node join/leave:
  - Updates Horde cluster membership (Registry + Supervisor)
  - Triggers AssignmentCoordinator refresh
  - Does not call PartitionManager directly (coordinator-driven architecture)

  TODO: Automatic reconciliation after Leader is implemented.
  """

  use GenServer
  require Logger

  alias QueueOfMatchmaking.Cluster.AssignmentCoordinator
  alias QueueOfMatchmaking.Horde.{Registry, Supervisor}

  # Client API

  @doc "Starts the Membership watcher."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)

    update_horde_membership()

    Logger.info("Membership watcher started, monitoring cluster topology")

    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node joined: #{node}")

    update_horde_membership()
    trigger_coordinator_refresh()

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("Node left: #{node}")

    update_horde_membership()
    trigger_coordinator_refresh()

    {:noreply, state}
  end

  # Private Helpers

  defp update_horde_membership do
    registry_members = build_registry_members()
    supervisor_members = build_supervisor_members()

    Registry.set_members(registry_members)
    Supervisor.set_members(supervisor_members)

    Logger.debug("Updated Horde membership: registry=#{inspect(registry_members)}, supervisor=#{inspect(supervisor_members)}")
  end

  defp build_registry_members do
    [node() | Node.list()]
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn node_name ->
      {QueueOfMatchmaking.Horde.Registry, node_name}
    end)
  end

  defp build_supervisor_members do
    [node() | Node.list()]
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn node_name ->
      {QueueOfMatchmaking.Horde.Supervisor, node_name}
    end)
  end

  defp trigger_coordinator_refresh do
    case AssignmentCoordinator.refresh() do
      :ok ->
        Logger.debug("Triggered AssignmentCoordinator refresh")

      error ->
        Logger.error("Failed to trigger coordinator refresh: #{inspect(error)}")
    end
  end
end
