defmodule QueueOfMatchmaking.Graphql.Types do
  @moduledoc """
  GraphQL type definitions for matchmaking API.
  """

  use Absinthe.Schema.Notation

  object :request_response do
    field(:ok, non_null(:boolean))
    field(:error, :string)
  end

  object :match_user do
    field(:user_id, non_null(:string))
    field(:user_rank, non_null(:integer))
  end

  object :match_payload do
    field(:users, non_null(list_of(non_null(:match_user))))
  end
end
