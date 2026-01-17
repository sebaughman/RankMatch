defmodule QueueOfMatchmaking.Index.UserIndexShard do
  @moduledoc """
    Tracks claimed user_ids to enforce cluster-wide single-enqueue semantics.

    IMPORTANT INVARIANT:
    - Claims are stored in shard process state only (in-memory).
    - If a PartitionWorker node crashes but the shard process survives,
      claims MAY become orphaned and block re-enqueue.

    TODO:
    - Track claim ownership (user_id -> owner_pid).
    - Monitor owner_pid and auto-release claims on :DOWN.
    - This is required to guarantee "users may safely re-enqueue after node crash".
  """

  use GenServer

  def start_link(opts) do
    shard_id = Keyword.fetch!(opts, :shard_id)
    name = QueueOfMatchmaking.Horde.Registry.via_tuple({:user_index_shard, shard_id})
    GenServer.start_link(__MODULE__, shard_id, name: name)
  end

  def child_spec(opts) do
    shard_id = Keyword.fetch!(opts, :shard_id)

    %{
      id: {:user_index_shard, shard_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @impl true
  def init(shard_id) do
    {:ok, %{shard_id: shard_id, claimed: MapSet.new()}}
  end

  @impl true
  def handle_call({:claim, user_id}, _from, state) do
    if MapSet.member?(state.claimed, user_id) do
      {:reply, {:error, :already_queued}, state}
    else
      new_claimed = MapSet.put(state.claimed, user_id)
      {:reply, :ok, %{state | claimed: new_claimed}}
    end
  end

  @impl true
  def handle_cast({:release, user_id}, state) do
    new_claimed = MapSet.delete(state.claimed, user_id)
    {:noreply, %{state | claimed: new_claimed}}
  end
end
