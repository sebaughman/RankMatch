defmodule QueueOfMatchmaking.Horde.Registry do
  @moduledoc """
  Wrapper for Horde.Registry providing cluster-wide process registration.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Horde.Registry, :start_link, [registry_options()]},
      type: :supervisor
    }
  end

  def via_tuple(key) do
    {:via, Horde.Registry, {__MODULE__, key}}
  end

  def lookup(key) do
    Horde.Registry.lookup(__MODULE__, key)
  end

  def members do
    Horde.Cluster.members(__MODULE__)
  end

  defp registry_options do
    [
      name: __MODULE__,
      keys: :unique
    ]
  end
end
