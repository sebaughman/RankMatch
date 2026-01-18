defmodule QueueOfMatchmaking.TestHelpers do
  @moduledoc """
  Test helpers for ensuring system readiness and deterministic test behavior.
  """

  alias QueueOfMatchmaking.Cluster.{Router, PartitionManager}
  alias QueueOfMatchmaking.Index.UserIndex

  @doc """
  Waits for the system to be fully initialized and ready for tests.
  Should be called in test setup to ensure partitions are running and routing works.
  """
  def wait_for_system_ready(timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_system_ready(deadline)
  end

  @doc """
  Generic polling helper that waits until a condition is met.
  Returns :ok if condition becomes true, raises if timeout.
  """
  def wait_until(check_fn, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(deadline, check_fn, timeout)
  end

  defp do_wait_until(deadline, check_fn, original_timeout) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Condition not met within #{original_timeout}ms timeout"
    end

    if check_fn.() do
      :ok
    else
      Process.sleep(10)
      do_wait_until(deadline, check_fn, original_timeout)
    end
  end

  @doc """
  Waits until a user is released from the UserIndex.
  Useful after operations that should release users (like matches or reserves).
  """
  def wait_for_user_released(user_id, timeout \\ 1000) do
    wait_until(
      fn ->
        case UserIndex.claim(user_id) do
          :ok ->
            UserIndex.release(user_id)
            true

          {:error, :already_queued} ->
            false
        end
      end,
      timeout
    )
  end

  @doc """
  Waits for all 20 partitions to be registered and ready.
  Uses a comprehensive approach: registration + routing + RPC health checks.
  Use this in tests that do cross-partition operations.
  """
  def wait_for_all_partitions_ready(timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_all_partitions(deadline, timeout)
  end

  defp do_wait_for_all_partitions(deadline, original_timeout) do
    if System.monotonic_time(:millisecond) > deadline do
      # Provide diagnostic info
      registered = count_registered_partitions()

      raise """
      Not all partitions ready within #{original_timeout}ms.
      Diagnostics:
        - Registered partitions: #{registered}/20
      """
    end

    # Check routing table exists and has 20 partitions
    routing_ready = case :persistent_term.get(:routing_table, nil) do
      {_epoch, table} when length(table) == 20 -> true
      _ -> false
    end

    # Check all 20 partitions are registered
    all_registered = count_registered_partitions() == 20

    if routing_ready and all_registered do
      # Now verify all partitions can handle RPC calls
      wait_for_all_partitions_rpc_ready(1, deadline)
      :ok
    else
      Process.sleep(50)
      do_wait_for_all_partitions(deadline, original_timeout)
    end
  end

  @doc """
  Waits for a specific partition to be RPC-ready (can handle GenServer calls).
  This verifies the partition is not just registered, but fully initialized.
  """
  def wait_for_partition_rpc_ready(partition_id, epoch \\ 1, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_rpc(partition_id, epoch, deadline, timeout)
  end

  defp do_wait_for_rpc(partition_id, epoch, deadline, original_timeout) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Partition #{partition_id} (epoch #{epoch}) not RPC-ready after #{original_timeout}ms"
    end

    # Look up partition directly from Horde Registry
    case QueueOfMatchmaking.Horde.Registry.lookup({:partition, epoch, partition_id}) do
      [{pid, _}] when is_pid(pid) ->
        # Verify partition can handle calls
        try do
          GenServer.call(pid, :health_check, 200)
          :ok
        catch
          :exit, {:timeout, _} ->
            Process.sleep(20)
            do_wait_for_rpc(partition_id, epoch, deadline, original_timeout)
          :exit, {:noproc, _} ->
            Process.sleep(20)
            do_wait_for_rpc(partition_id, epoch, deadline, original_timeout)
        end

      [] ->
        Process.sleep(20)
        do_wait_for_rpc(partition_id, epoch, deadline, original_timeout)
    end
  end

  defp wait_for_all_partitions_rpc_ready(epoch, deadline) do
    # Check all 20 partitions can handle RPC calls
    Enum.each(1..20, fn idx ->
      start_rank = (idx - 1) * 500
      end_rank = if idx == 20, do: 10_000, else: idx * 500 - 1

      partition_id =
        "p-#{String.pad_leading(to_string(start_rank), 5, "0")}-#{String.pad_leading(to_string(end_rank), 5, "0")}"

      remaining_time = deadline - System.monotonic_time(:millisecond)
      if remaining_time > 0 do
        do_wait_for_rpc(partition_id, epoch, deadline, remaining_time)
      else
        raise "Timeout waiting for partition #{partition_id} RPC readiness"
      end
    end)
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
      # Extra wait to ensure all partition workers are fully initialized
      Process.sleep(150)
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
