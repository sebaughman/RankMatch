defmodule QueueOfMatchmaking.Horde.Supervisor do
  @moduledoc """
  Wrapper for Horde.DynamicSupervisor providing distributed child supervision.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Horde.DynamicSupervisor, :start_link, [supervisor_options()]},
      type: :supervisor
    }
  end

  def start_child(child_spec) do
    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def terminate_child(pid_or_id) do
    Horde.DynamicSupervisor.terminate_child(__MODULE__, pid_or_id)
  end

  defp supervisor_options do
    [
      name: __MODULE__,
      strategy: :one_for_one
    ]
  end
end
