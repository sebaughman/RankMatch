# Load Test Benchmark Runner
#
# Runs multiple load test scenarios to measure system performance
# under different conditions.
#
# Usage:
#   mix run load_test.exs

benchmarks = [
  %{
    name: "1.5k rps / 10s / balanced_pairs (throughput)",
    args: [
      "--rps",
      "1500",
      "--duration_s",
      "10",
      "--concurrency",
      "2000",
      "--mode",
      "balanced_pairs"
    ]
  },
  %{
    name: "1.5k rps / 10s / uniform (realistic workload)",
    args: [
      "--rps",
      "1500",
      "--duration_s",
      "10",
      "--concurrency",
      "2000",
      "--mode",
      "uniform"
    ]
  },
  %{
    name: "1k rps / 20s / no_match (queue buildup stress)",
    args: [
      "--rps",
      "1000",
      "--duration_s",
      "20",
      "--concurrency",
      "2000",
      "--mode",
      "no_match"
    ]
  }
]

Enum.each(benchmarks, fn %{name: name, args: args} ->
  IO.puts("\n==============================")
  IO.puts("BENCH: #{name}")
  IO.puts("==============================\n")

  Mix.Task.clear()
  Mix.Task.run("load_test", args)
end)

IO.puts("\n==============================")
IO.puts("All benchmarks complete!")
IO.puts("==============================\n")
