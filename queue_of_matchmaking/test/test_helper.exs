ExUnit.start()

# Ensure endpoint is started for subscription tests
{:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
