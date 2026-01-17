defmodule QueueOfMatchmaking.Cluster.Router do
  @moduledoc """
  Routes matchmaking requests to appropriate partitions based on rank.
  Maintains routing table built from AssignmentCoordinator snapshots.
  """

  use GenServer
  require Logger

  alias QueueOfMatchmaking.Cluster.AssignmentCoordinator

  @pubsub QueueOfMatchmaking.PubSub
  @topic "assignments"
  @persistent_term_key :routing_table

  # Client API

  @doc """
  Starts the Router GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Routes a rank to its owning partition with epoch metadata.
  Reads from :persistent_term for hot-path performance.
  """
  def route_with_epoch(rank) when is_integer(rank) and rank >= 0 and rank <= 10_000 do
    case :persistent_term.get(@persistent_term_key, {nil, []}) do
      {nil, []} ->
        {:error, :no_partition}

      {routing_epoch, table} ->
        current_epoch = coordinator_module().current_epoch()

        if routing_epoch != current_epoch do
          Logger.error(
            "Router epoch mismatch: routing_epoch=#{routing_epoch}, current_epoch=#{current_epoch}"
          )

          {:error, :stale_routing_snapshot}
        else
          find_partition(rank, table)
        end
    end
  end

  def route_with_epoch(_rank) do
    {:error, :invalid_rank}
  end


  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
    Process.sleep(10)

    snapshot = coordinator_module().snapshot()
    table = build_routing_table(snapshot)

    :persistent_term.put(@persistent_term_key, {snapshot.epoch, table})

    {:ok, %{routing_epoch: snapshot.epoch}}
  end

  @impl true
  def handle_info({:assignments_updated, snapshot}, _state) do
    table = build_routing_table(snapshot)
    :persistent_term.put(@persistent_term_key, {snapshot.epoch, table})

    {:noreply, %{routing_epoch: snapshot.epoch}}
  end

  defp build_routing_table(snapshot) do
    snapshot.assignments
    |> Enum.sort_by(& &1.range_start)
  end

  defp find_partition(rank, table) do
    case Enum.find(table, fn partition ->
           rank >= partition.range_start and rank <= partition.range_end
         end) do
      nil ->
        {:error, :no_partition}

      partition ->
        {:ok,
         %{
           epoch: partition.epoch,
           partition_id: partition.partition_id,
           node: partition.node
         }}
    end
  end

  defp coordinator_module do
    Application.get_env(
      :queue_of_matchmaking,
      :assignment_coordinator_module,
      AssignmentCoordinator
    )
  end
end
