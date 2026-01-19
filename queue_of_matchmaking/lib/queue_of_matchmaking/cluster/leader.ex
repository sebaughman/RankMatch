defmodule QueueOfMatchmaking.Cluster.Leader do
  @moduledoc """
  Deterministic leader election for single-writer rebalance operations.

  Split-brain limitation: each network partition picks a leader independently.
  When the network heals, the cluster converges. Transient dual leaders are
  acceptable until later hardening. TODO...
  """

  @doc """
  Returns the leader node from the current cluster.

  The leader is the node with the lexicographically smallest name.
  """
  def leader_node do
    leader_node([node() | Node.list()])
  end

  @doc """
  Returns the leader node from an explicit list of nodes.

  Pure helper for tests and callers with an explicit node list.
  """
  def leader_node([]), do: nil
  def leader_node(nodes) when is_list(nodes) do
    Enum.min(nodes)
  end

  @doc """
  Returns true if the current node is the leader.
  """
  def am_leader?, do: node() == leader_node()
  def am_leader?([]), do: false
  def am_leader?(nodes), do: node() == leader_node(nodes)
end
