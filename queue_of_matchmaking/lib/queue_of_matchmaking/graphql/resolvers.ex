defmodule QueueOfMatchmaking.Graphql.Resolvers do
  @moduledoc """
  GraphQL resolver functions for matchmaking mutations.
  """

  def add_request(args, _resolution) do
    user_id = args[:user_id] || args[:userId]
    rank = args[:rank]

    with :ok <- validate_input(user_id, rank),
         :ok <- QueueOfMatchmaking.Index.UserIndex.claim(user_id) do
      # Cleanup rule: From this point forward, any error path MUST call
      # UserIndex.release(user_id). This will be implemented when routing/enqueue
      {:ok, %{ok: true, error: nil}}
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
end
