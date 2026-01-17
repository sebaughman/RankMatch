defmodule QueueOfMatchmaking.TestHelpers do
  @moduledoc """
  Test helpers for ensuring system readiness and deterministic test behavior.
  """

  alias QueueOfMatchmaking.Cluster.{Router, PartitionManager}

  @doc """
  Waits for the system to be fully initialized and ready for tests.
  Should be called in test setup to ensure partitions are running and routing works.
  """
  def wait_for_system_ready(timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_system_ready(deadline)
  end

  defp do_wait_for_system_ready(deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      # Provide diagnostic info on what's missing
      state = PartitionManager.debug_state()

      can_route =
        case Router.route_with_epoch(500) do
          {:ok, _} -> true
          _ -> false
        end

      registered_count = count_registered_partitions()

      raise """
      System did not become ready within timeout.
      Diagnostics:
        - PartitionManager count: #{state.local_partition_count}
        - Can route: #{can_route}
        - Registered partitions: #{registered_count}/20
      """
    end

    # Check if PartitionManager has partitions
    state = PartitionManager.debug_state()

    # Check if Router can route
    can_route =
      case Router.route_with_epoch(500) do
        {:ok, _} -> true
        _ -> false
      end

    # Check if all 20 partitions are registered
    all_partitions_registered = count_registered_partitions() == 20

    if state.local_partition_count > 0 and can_route and all_partitions_registered do
      :ok
    else
      Process.sleep(10)
      do_wait_for_system_ready(deadline)
    end
  end

  defp count_registered_partitions do
    Enum.count(1..20, fn idx ->
      start_rank = (idx - 1) * 500
      end_rank = if idx == 20, do: 10_000, else: idx * 500 - 1

      partition_id =
        "p-#{String.pad_leading(to_string(start_rank), 5, "0")}-#{String.pad_leading(to_string(end_rank), 5, "0")}"

      case QueueOfMatchmaking.Horde.Registry.lookup({:partition, 1, partition_id}) do
        [{_pid, _}] -> true
        [] -> false
      end
    end)
  end
end
