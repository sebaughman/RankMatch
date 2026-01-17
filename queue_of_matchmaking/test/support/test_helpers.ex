defmodule QueueOfMatchmaking.TestHelpers do
  @moduledoc """
  Test helpers for ensuring system readiness and deterministic test behavior.
  """

  alias QueueOfMatchmaking.Cluster.{Router, PartitionManager}

  @doc """
  Waits for the system to be fully initialized and ready for tests.
  Should be called in test setup to ensure partitions are running and routing works.
  """
  def wait_for_system_ready(timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_system_ready(deadline)
  end

  defp do_wait_for_system_ready(deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "System did not become ready within timeout"
    end

    # Check if PartitionManager has partitions
    state = PartitionManager.debug_state()

    # Check if Router can route
    can_route =
      case Router.route_with_epoch(500) do
        {:ok, _} -> true
        _ -> false
      end

    if state.local_partition_count > 0 and can_route do
      :ok
    else
      Process.sleep(10)
      do_wait_for_system_ready(deadline)
    end
  end
end
