defmodule QueueOfMatchmaking.Cluster.PartitionManager do
  @moduledoc """
  Executes partition lifecycle based on AssignmentCoordinator snapshots.

  It does not compute assignments. It ensures partitions assigned to this node
  for the active epoch are running.
  """

  use GenServer
  require Logger

  alias QueueOfMatchmaking.Cluster.AssignmentCoordinator
  alias QueueOfMatchmaking.Horde.{Registry, Supervisor}
  alias QueueOfMatchmaking.Matchmaking.PartitionWorker
  alias QueueOfMatchmaking.Config

  # Client API

  @doc "Starts the PartitionManager."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers manual reconciliation of partitions."
  def rebalance do
    GenServer.call(__MODULE__, :rebalance)
  end

  @doc "Returns a sanitized view of current state for debugging."
  def debug_state do
    GenServer.call(__MODULE__, :debug_state)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    snapshot = AssignmentCoordinator.snapshot()
    assignments = filter_local_assignments(snapshot)

    Logger.info(
      "PartitionManager starting: epoch=#{snapshot.epoch}, local_partition_count=#{length(assignments)}"
    )

    local_partitions = start_assigned_partitions(assignments)

    AssignmentCoordinator.subscribe()

    {:ok,
     %{
       active_epoch: snapshot.epoch,
       assignments: assignments,
       local_partitions: local_partitions,
       reconcile_scheduled?: false
     }}
  end

  @impl true
  def handle_call(:rebalance, _from, state) do
    snapshot = AssignmentCoordinator.snapshot()

    new_state = do_reconcile(state, snapshot)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:debug_state, _from, state) do
    sanitized = %{
      active_epoch: state.active_epoch,
      assignment_count: length(state.assignments),
      local_partition_count: map_size(state.local_partitions),
      partition_keys: Map.keys(state.local_partitions)
    }

    {:reply, sanitized, state}
  end

  @impl true
  def handle_info({:assignments_updated, snapshot}, state) do
    Logger.debug("assignments_updated received: epoch=#{snapshot.epoch}")

    if state.reconcile_scheduled? do
      Logger.debug("Auto-reconcile already scheduled, skipping")
      {:noreply, state}
    else
      Logger.info("Leader scheduling auto-reconcile in 25ms")
      Process.send_after(self(), {:auto_rebalance, snapshot}, 25)
      {:noreply, %{state | reconcile_scheduled?: true}}
    end
  end

  @impl true
  def handle_info({:auto_rebalance, snapshot}, state) do
    Logger.debug("Executing auto-reconcile")
    new_state = do_reconcile(state, snapshot)
    {:noreply, %{new_state | reconcile_scheduled?: false}}
  end

  # Private Helpers

  defp do_reconcile(state, snapshot) do
    state
    |> maybe_update_epoch(snapshot.epoch)
    |> reconcile(snapshot)
  end

  defp maybe_update_epoch(state, epoch) when state.active_epoch == epoch, do: state

  defp maybe_update_epoch(state, epoch) do
    Logger.info("Epoch changed from #{state.active_epoch} to #{epoch}")
    %{state | active_epoch: epoch}
  end

  defp reconcile(state, snapshot) do
    assignments = filter_local_assignments(snapshot)
    assignment_index = index_assignments(assignments)

    {to_start, to_stop} =
      diff_partition_keys(assignments, Map.keys(state.local_partitions))

    local_partitions =
      state.local_partitions
      |> start_missing_partitions(to_start, assignment_index)
      |> stop_extra_partitions(to_stop)

    Logger.info(
      "Reconciled: started=#{MapSet.size(to_start)}, stopped=#{MapSet.size(to_stop)}, epoch=#{state.active_epoch}"
    )

    %{state | assignments: assignments, local_partitions: local_partitions}
  end

  defp diff_partition_keys(desired_assignments, actual_keys) do
    desired = MapSet.new(desired_assignments, fn a -> {a.epoch, a.partition_id} end)
    actual = MapSet.new(actual_keys)

    to_start = MapSet.difference(desired, actual)
    to_stop = MapSet.difference(actual, desired)

    {to_start, to_stop}
  end

  defp index_assignments(assignments) do
    Map.new(assignments, fn a -> {{a.epoch, a.partition_id}, a} end)
  end

  defp start_assigned_partitions(assignments) do
    Enum.reduce(assignments, %{}, fn assignment, acc ->
      case start_partition(assignment) do
        {:ok, pid} ->
          Map.put(acc, {assignment.epoch, assignment.partition_id}, pid)

        {:error, reason} ->
          Logger.error(
            "Failed to start partition #{assignment.partition_id} (epoch #{assignment.epoch}): #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp start_missing_partitions(local_partitions, to_start, assignment_index) do
    Enum.reduce(to_start, local_partitions, fn key = {epoch, partition_id}, acc ->
      case Map.fetch(assignment_index, key) do
        :error ->
          Logger.error(
            "Missing assignment for partition #{partition_id} (epoch #{epoch}) while starting"
          )

          acc

        {:ok, assignment} ->
          case start_partition(assignment) do
            {:ok, pid} ->
              Map.put(acc, key, pid)

            {:error, reason} ->
              Logger.error(
                "Failed to start partition #{partition_id} (epoch #{epoch}): #{inspect(reason)}"
              )

              acc
          end
      end
    end)
  end

  defp stop_extra_partitions(local_partitions, to_stop) do
    Enum.reduce(to_stop, local_partitions, fn key, acc ->
      stop_partition(key)
      Map.delete(acc, key)
    end)
  end

  defp filter_local_assignments(snapshot) do
    Enum.filter(snapshot.assignments, fn assignment ->
      assignment.node == node() and assignment.epoch == snapshot.epoch
    end)
  end

  defp start_partition(%{epoch: epoch, partition_id: partition_id} = assignment) do
    worker_opts = [
      epoch: epoch,
      partition_id: partition_id,
      range_start: assignment.range_start,
      range_end: assignment.range_end,
      config: Config.matchmaking_config(),
      name: Registry.via_partition(epoch, partition_id)
    ]

    child_spec = %{
      id: {:partition_worker, epoch, partition_id},
      start: {PartitionWorker, :start_link, [worker_opts]},
      restart: :transient
    }

    case Supervisor.start_child(child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_partition({epoch, partition_id}) do
    Logger.info("Stopping partition #{partition_id} (epoch #{epoch}) - no longer assigned")

    case Supervisor.terminate_child({:partition_worker, epoch, partition_id}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to stop partition #{partition_id} (epoch #{epoch}): #{inspect(reason)}"
        )

        :ok
    end
  end
end
