defmodule QueueOfMatchmaking.Matchmaking.WideningTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Matchmaking.Widening

  describe "allowed_diff/2" do
    setup do
      config = %{
        widening_step_ms: 200,
        widening_step_diff: 25,
        widening_cap: 1000
      }

      {:ok, config: config}
    end

    test "returns 0 for age less than step_ms", %{config: config} do
      assert Widening.allowed_diff(0, config) == 0
      assert Widening.allowed_diff(100, config) == 0
      assert Widening.allowed_diff(199, config) == 0
    end

    test "returns step_diff at first step boundary", %{config: config} do
      assert Widening.allowed_diff(200, config) == 25
      assert Widening.allowed_diff(250, config) == 25
      assert Widening.allowed_diff(399, config) == 25
    end

    test "increases by step_diff at each step", %{config: config} do
      assert Widening.allowed_diff(400, config) == 50
      assert Widening.allowed_diff(600, config) == 75
      assert Widening.allowed_diff(800, config) == 100
      assert Widening.allowed_diff(1000, config) == 125
    end

    test "caps at widening_cap", %{config: config} do
      assert Widening.allowed_diff(8000, config) == 1000
      assert Widening.allowed_diff(10000, config) == 1000
      assert Widening.allowed_diff(100_000, config) == 1000
    end

    test "handles exact step boundaries", %{config: config} do
      assert Widening.allowed_diff(200, config) == 25
      assert Widening.allowed_diff(400, config) == 50
      assert Widening.allowed_diff(600, config) == 75
    end

    test "uses floor division for partial steps", %{config: config} do
      assert Widening.allowed_diff(201, config) == 25
      assert Widening.allowed_diff(399, config) == 25
      assert Widening.allowed_diff(401, config) == 50
    end
  end
end
