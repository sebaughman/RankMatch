defmodule QueueOfMatchmaking.Horde.Registry do
  @moduledoc """
  Wrapper for Horde.Registry providing cluster-wide process registration.

  ## Epoch-Scoped Partition Identity

  Partitions are registered using epoch-scoped keys: {:partition, epoch, partition_id}.
  This enables future multi-epoch operation where old and new partition assignments
  can coexist during warm-up and cutover phases without naming collisions.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Horde.Registry, :start_link, [registry_options()]},
      type: :supervisor
    }
  end

  def via_tuple(key) do
    {:via, Horde.Registry, {__MODULE__, key}}
  end

  def via_partition(epoch, partition_id) do
    via_tuple({:partition, epoch, partition_id})
  end

  def lookup(key) do
    Horde.Registry.lookup(__MODULE__, key)
  end

  def members do
    Horde.Cluster.members(__MODULE__)
  end

  defp registry_options do
    [
      name: __MODULE__,
      keys: :unique
    ]
  end
end
