defmodule QueueOfMatchmaking.Matchmaking.Backpressure do
  @moduledoc """
  Backpressure decision logic for partition workers.
  Must be called from within the PartitionWorker process.
  """

  @doc """
  Checks if the partition should reject new enqueue requests due to overload.
  """
  def check_overload(state) do
    limits = state.config.backpressure
    msg_queue_limit = limits[:message_queue_limit]
    queued_count_limit = limits[:queued_count_limit]

    cond do
      exceeds_message_queue_limit?(msg_queue_limit) ->
        {:error, :overloaded}

      state.queued_count > queued_count_limit ->
        {:error, :overloaded}

      true ->
        :ok
    end
  end

  defp exceeds_message_queue_limit?(limit) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} -> len > limit
      nil -> false
    end
  end
end
