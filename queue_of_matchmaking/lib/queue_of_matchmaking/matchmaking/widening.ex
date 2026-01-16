defmodule QueueOfMatchmaking.Matchmaking.Widening do
  @moduledoc """
  Time-based rank difference widening for gradual matching expansion.
  """

  @doc """
  Computes allowed rank difference based on ticket age.
  """
  def allowed_diff(age_ms, config) do
    step_ms = config.widening_step_ms
    step_diff = config.widening_step_diff
    cap = config.widening_cap

    computed = div(age_ms, step_ms) * step_diff
    min(computed, cap)
  end
end
