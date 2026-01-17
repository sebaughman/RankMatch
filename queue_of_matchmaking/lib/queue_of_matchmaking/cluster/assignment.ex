defmodule QueueOfMatchmaking.Cluster.Assignment do
  @moduledoc """
  Computes partition assignments for distributed matchmaking.
  Generates fixed rank ranges and assigns them to nodes using round-robin distribution.

  ## Epoch Scaffolding

  All assignments include an epoch field read from configuration.
  This is structural scaffolding for future versioned assignment functionality.

  Epoch defaults to 1 and can be configured via :epoch in application config.
  """

  @doc """
  Computes partition assignments for the given nodes.
  Returns list of assignment maps with partition_id, range, and assigned node.
  """
  def compute_assignments(nodes, config) do
    case nodes do
      [] ->
        []

      _ ->
        sorted_nodes = Enum.sort(nodes)
        epoch = config[:epoch] || 1
        rank_min = config[:rank_min] || 0
        rank_max = config[:rank_max] || 10_000
        partition_count = config[:partition_count] || 20

        0..(partition_count - 1)
        |> Enum.map(fn partition_index ->
          {range_start, range_end} =
            compute_range(partition_index, rank_min, rank_max, partition_count)

          node = Enum.at(sorted_nodes, rem(partition_index, length(sorted_nodes)))

          %{
            epoch: epoch,
            partition_id: format_partition_id(range_start, range_end),
            range_start: range_start,
            range_end: range_end,
            node: node
          }
        end)
    end
  end

  defp compute_range(partition_index, rank_min, rank_max, partition_count) do
    total_range = rank_max - rank_min + 1
    base_width = div(total_range, partition_count)

    range_start = rank_min + partition_index * base_width

    range_end =
      if partition_index == partition_count - 1 do
        rank_max
      else
        range_start + base_width - 1
      end

    {range_start, range_end}
  end

  defp format_partition_id(range_start, range_end) do
    "p-#{String.pad_leading(to_string(range_start), 5, "0")}-#{String.pad_leading(to_string(range_end), 5, "0")}"
  end
end
