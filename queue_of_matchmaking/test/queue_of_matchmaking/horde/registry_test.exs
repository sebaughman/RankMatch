defmodule QueueOfMatchmaking.Horde.RegistryTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Horde.Registry

  describe "epoch-scoped partition identity" do
    test "via_partition/2 generates correct via tuple" do
      via = Registry.via_partition(1, "p-00000-00499")
      assert via == {:via, Horde.Registry, {Registry, {:partition, 1, "p-00000-00499"}}}
    end

    test "two different epochs can register the same partition_id without collision" do
      partition_id = "test-partition-#{:erlang.unique_integer([:positive])}"

      {:ok, pid1} =
        Agent.start_link(fn -> :epoch1 end, name: Registry.via_partition(1, partition_id))

      # Small sleep to allow registration to stabilize in Horde
      Process.sleep(10)

      {:ok, pid2} =
        Agent.start_link(fn -> :epoch2 end, name: Registry.via_partition(2, partition_id))

      # Small sleep to allow registration to stabilize in Horde
      Process.sleep(10)

      assert pid1 != pid2

      assert [{^pid1, _}] = Registry.lookup({:partition, 1, partition_id})
      assert [{^pid2, _}] = Registry.lookup({:partition, 2, partition_id})

      Agent.stop(pid1)
      Agent.stop(pid2)
    end

    test "lookup returns empty list when partition not registered" do
      assert [] = Registry.lookup({:partition, 99, "nonexistent"})
    end
  end
end
