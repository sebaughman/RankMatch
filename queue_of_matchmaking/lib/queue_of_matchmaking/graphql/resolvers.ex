defmodule QueueOfMatchmaking.Graphql.Resolvers do
  @moduledoc """
  GraphQL resolver functions for matchmaking mutations.
  """

  alias QueueOfMatchmaking.Index.UserIndex
  alias QueueOfMatchmaking.Matchmaking.PartitionWorker
  alias QueueOfMatchmaking.Cluster.Router
  alias QueueOfMatchmaking.Horde.Registry
  alias QueueOfMatchmaking.Config

  def add_request(args, _resolution) do
    user_id = args[:user_id] || args[:userId]
    rank = args[:rank]

    with :ok <- validate_input(user_id, rank),
         :ok <- UserIndex.claim(user_id) do
      attempt_enqueue(user_id, rank)
    else
      {:error, :already_queued} ->
        {:ok, %{ok: false, error: "already_queued"}}

      {:error, :index_unavailable} ->
        {:ok, %{ok: false, error: "momentary interruption, try again"}}

      {:error, reason} when is_binary(reason) ->
        {:ok, %{ok: false, error: reason}}
    end
  end

  defp validate_input(user_id, rank)
       when is_binary(user_id) and user_id != "" and is_integer(rank) and rank >= 0 do
    :ok
  end

  defp validate_input(user_id, _rank) when not is_binary(user_id) or user_id == "" do
    {:error, "userId must be a non-empty string"}
  end

  defp validate_input(_user_id, rank) when not is_integer(rank) or rank < 0 do
    {:error, "rank must be a non-negative integer"}
  end

  defp attempt_enqueue(user_id, rank) do
    timeout = Config.enqueue_timeout_ms()

    try do
      with {:ok, route} <- Router.route_with_epoch(rank),
           envelope <- build_envelope(route, user_id, rank),
           {:ok, worker_pid} <- lookup_partition(route.epoch, route.partition_id),
           :ok <- PartitionWorker.enqueue(worker_pid, envelope, timeout) do
        {:ok, %{ok: true, error: nil}}
      else
        {:error, :stale_epoch} ->
          release_and_error(user_id, "stale_epoch")

        {:error, :overloaded} ->
          release_and_error(user_id, "overloaded")

        {:error, :out_of_range} ->
          release_and_error(user_id, "invalid_rank")

        {:error, :partition_not_found} ->
          release_and_error(user_id, "no_partition")
      end
    catch
      :exit, _ ->
        release_and_error(user_id, "overloaded")
    end
  end

  defp lookup_partition(epoch, partition_id) do
    case Registry.lookup({:partition, epoch, partition_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :partition_not_found}
    end
  end

  defp build_envelope(route, user_id, rank) do
    %{
      epoch: route.epoch,
      partition_id: route.partition_id,
      user_id: user_id,
      rank: rank
    }
  end

  defp release_and_error(user_id, error_string) do
    UserIndex.release(user_id)
    {:ok, %{ok: false, error: error_string}}
  end
end
