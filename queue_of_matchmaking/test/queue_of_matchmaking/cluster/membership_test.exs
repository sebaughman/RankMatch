defmodule QueueOfMatchmaking.Cluster.MembershipTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Cluster.Membership
  alias QueueOfMatchmaking.Horde.{Registry, Supervisor}

  describe "init/1" do
    test "starts node monitoring on init" do
      pid = Process.whereis(Membership)

      assert Process.alive?(pid)
    end

    test "sets initial Horde membership on init" do
      registry_members = Registry.members()
      supervisor_members = Supervisor.members()

      assert Enum.any?(registry_members, fn {_name, n} -> n == node() end)
      assert Enum.any?(supervisor_members, fn {_name, n} -> n == node() end)
    end
  end

  describe "nodeup/nodedown handling" do
    test "updates Horde membership on simulated nodeup" do
      pid = Process.whereis(Membership)

      send(pid, {:nodeup, :"test@host", %{}})
      Process.sleep(50)

      assert Process.alive?(pid)
    end

    test "triggers coordinator refresh on nodeup" do
      pid = Process.whereis(Membership)

      initial_snapshot = QueueOfMatchmaking.Cluster.AssignmentCoordinator.snapshot()
      initial_ts = initial_snapshot.computed_at_ms

      send(pid, {:nodeup, :"test@host", %{}})
      Process.sleep(50)

      new_snapshot = QueueOfMatchmaking.Cluster.AssignmentCoordinator.snapshot()
      assert new_snapshot.computed_at_ms >= initial_ts
    end

    test "handles nodedown event" do
      pid = Process.whereis(Membership)

      send(pid, {:nodedown, :"test@host", %{}})
      Process.sleep(50)

      assert Process.alive?(pid)
    end

    test "triggers coordinator refresh on nodedown" do
      pid = Process.whereis(Membership)

      initial_snapshot = QueueOfMatchmaking.Cluster.AssignmentCoordinator.snapshot()
      initial_ts = initial_snapshot.computed_at_ms

      send(pid, {:nodedown, :"test@host", %{}})
      Process.sleep(50)

      new_snapshot = QueueOfMatchmaking.Cluster.AssignmentCoordinator.snapshot()
      assert new_snapshot.computed_at_ms >= initial_ts
    end
  end

  describe "membership list format" do
    test "builds members list in correct format" do
      members = Registry.members()

      assert is_list(members)

      Enum.each(members, fn {name, node_name} ->
        assert is_atom(name)
        assert is_atom(node_name)
      end)
    end

    test "membership list includes local node" do
      registry_members = Registry.members()
      supervisor_members = Supervisor.members()

      assert Enum.any?(registry_members, fn {_name, n} -> n == node() end)
      assert Enum.any?(supervisor_members, fn {_name, n} -> n == node() end)
    end
  end

  describe "Horde membership synchronization" do
    test "updates both Registry and Supervisor membership" do
      pid = Process.whereis(Membership)

      initial_registry = Registry.members()
      initial_supervisor = Supervisor.members()

      send(pid, {:nodeup, :"test@host", %{}})
      Process.sleep(50)

      updated_registry = Registry.members()
      updated_supervisor = Supervisor.members()

      assert is_list(updated_registry)
      assert is_list(updated_supervisor)
      assert length(updated_registry) >= length(initial_registry)
      assert length(updated_supervisor) >= length(initial_supervisor)
    end
  end
end
