defmodule QueueOfMatchmaking.Index.UserIndex do
  @moduledoc """
  Coordinator for cluster-wide user duplicate prevention.
  In-memory, cluster-wide best-effort claim tracking; claims are lost on node restart.
  """

  use GenServer

  @retry_attempts 3
  @retry_delay_ms 20

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Claim a user ID for queueing. Returns error if already queued.
  """
  def claim(user_id) do
    shard_id = shard_for_user(user_id)
    call_with_retry(shard_id, {:claim, user_id})
  end

  @doc """
  Release a user ID claim.
  """
  def release(user_id) do
    shard_id = shard_for_user(user_id)
    via_tuple = QueueOfMatchmaking.Horde.Registry.via_tuple({:user_index_shard, shard_id})
    GenServer.cast(via_tuple, {:release, user_id})
  end

  @impl true
  def init(:ok) do
    shard_count = Application.fetch_env!(:queue_of_matchmaking, :user_index_shard_count)
    start_all_shards(shard_count)
    {:ok, %{shard_count: shard_count}}
  end

  defp start_all_shards(shard_count) do
    Enum.each(0..(shard_count - 1), fn shard_id ->
      child_spec = QueueOfMatchmaking.Index.UserIndexShard.child_spec(shard_id: shard_id)

      case QueueOfMatchmaking.Horde.Supervisor.start_child(child_spec) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, {:already_present, _}} ->
          :ok

        {:error, reason} ->
          raise "Failed to start user_index_shard #{shard_id}: #{inspect(reason)}"
      end
    end)
  end

  defp shard_for_user(user_id) do
    shard_count = GenServer.call(__MODULE__, :get_shard_count)
    :erlang.phash2(user_id, shard_count)
  end

  defp call_with_retry(shard_id, message, attempt \\ 1) do
    via_tuple = QueueOfMatchmaking.Horde.Registry.via_tuple({:user_index_shard, shard_id})

    try do
      GenServer.call(via_tuple, message)
    catch
      :exit, {:noproc, _} when attempt < @retry_attempts ->
        Process.sleep(@retry_delay_ms)
        call_with_retry(shard_id, message, attempt + 1)

      :exit, {:noproc, _} ->
        {:error, :index_unavailable}
    end
  end

  @impl true
  def handle_call(:get_shard_count, _from, state) do
    {:reply, state.shard_count, state}
  end
end
