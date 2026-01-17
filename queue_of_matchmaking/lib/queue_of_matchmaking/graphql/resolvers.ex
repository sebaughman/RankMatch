defmodule QueueOfMatchmaking.Graphql.Resolvers do
  @moduledoc """
  GraphQL resolver functions for matchmaking mutations.
  """

  alias QueueOfMatchmaking.Index.UserIndex
  alias QueueOfMatchmaking.Matchmaking.PartitionWorker

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
    worker_name = QueueOfMatchmaking.PartitionWorker.FullRange
    timeout = Application.fetch_env!(:queue_of_matchmaking, :enqueue_timeout_ms)

    try do
      case PartitionWorker.enqueue(worker_name, user_id, rank, timeout) do
        :ok ->
          {:ok, %{ok: true, error: nil}}

        {:error, :overloaded} ->
          release_and_error(user_id, "overloaded")

        {:error, :out_of_range} ->
          release_and_error(user_id, "invalid_rank")
      end
    catch
      :exit, _ ->
        release_and_error(user_id, "overloaded")
    end
  end

  defp release_and_error(user_id, error_string) do
    UserIndex.release(user_id)
    {:ok, %{ok: false, error: error_string}}
  end
end
