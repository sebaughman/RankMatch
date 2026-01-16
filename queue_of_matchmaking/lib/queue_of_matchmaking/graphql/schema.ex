defmodule QueueOfMatchmaking.Graphql.Schema do
  @moduledoc """
  Absinthe GraphQL schema for matchmaking API.
  """

  use Absinthe.Schema
  import_types(QueueOfMatchmaking.Graphql.Types)

  query do
    field :health, :string do
      resolve(fn _, _ -> {:ok, "ok"} end)
    end
  end

  mutation do
    field :add_request, :request_response do
      arg(:user_id, non_null(:string))
      arg(:rank, non_null(:integer))

      resolve(&QueueOfMatchmaking.Graphql.Resolvers.add_request/2)
    end
  end

  subscription do
    field :match_found, :match_payload do
      arg(:user_id, non_null(:string))

      config(fn args, _resolution ->
        user_id = args[:user_id] || args[:userId]

        if is_nil(user_id) or user_id == "" do
          {:error, "userId required"}
        else
          {:ok, topic: "matchFound:#{user_id}"}
        end
      end)
    end
  end
end
