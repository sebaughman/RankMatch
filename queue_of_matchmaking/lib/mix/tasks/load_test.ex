defmodule Mix.Tasks.LoadTest do
  @moduledoc """
  Runs a high-throughput GraphQL load test against /graphql.

  ## Usage

      mix load_test --rps 10000 --duration_s 10 --concurrency 2000 --mode balanced_pairs

  ## Options

    * `--url` - GraphQL endpoint URL (default: http://localhost:4000/graphql)
    * `--rps` - Target requests per second (default: 10000)
    * `--duration_s` - Test duration in seconds (default: 10)
    * `--concurrency` - Max concurrent requests (default: 2000)
    * `--tick_ms` - Pacing tick interval in milliseconds (default: 100)
    * `--rank_min` - Minimum rank value (default: from config)
    * `--rank_max` - Maximum rank value (default: from config)
    * `--mode` - Request distribution mode (default: balanced_pairs)
      - `balanced_pairs`: Adjacent rank pairs for fast matching
      - `uniform`: Uniform random distribution for queue stress
      - `no_match`: Widely spaced ranks to prevent matching

  """
  use Mix.Task

  @shortdoc "Runs a high-throughput GraphQL load test against /graphql."

  @default_url "http://localhost:4000/graphql"
  @default_rps 10_000
  @default_duration_s 10
  @default_concurrency 2_000
  @default_tick_ms 100

  @impl true
  def run(argv) do
    # Start only the dependencies needed for HTTP client
    _ = Application.ensure_all_started(:jason)
    _ = Application.ensure_all_started(:inets)

  :httpc.set_options([
    {:max_sessions, 500},           # More parallel HTTP/1.1 connections
    {:max_keep_alive_length, 50},   # Reuse connections more
    {:max_pipeline_length, 100}     # More requests per connection
  ])

    opts = parse_args(argv)
    state = new_state(opts)

    IO.puts("""
    Load test starting
      url: #{state.url}
      rps: #{state.rps}
      duration_s: #{state.duration_s}
      concurrency: #{state.concurrency}
      tick_ms: #{state.tick_ms}
      rank_min..max: #{state.rank_min}..#{state.rank_max}
      mode: #{state.mode}
    """)

    before_mem = snapshot_memory()

    try do
      {elapsed_ms, results} = run_load(state)
      after_mem = snapshot_memory()
      report(state, elapsed_ms, results, before_mem, after_mem)
    after
      :ok
    end
  end

  # -----------------------
  # Args / state
  # -----------------------

  defp parse_args(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          url: :string,
          rps: :integer,
          duration_s: :integer,
          concurrency: :integer,
          tick_ms: :integer,
          rank_min: :integer,
          rank_max: :integer,
          mode: :string
        ]
      )

    %{
      url: Keyword.get(opts, :url, @default_url),
      rps: Keyword.get(opts, :rps, @default_rps),
      duration_s: Keyword.get(opts, :duration_s, @default_duration_s),
      concurrency: Keyword.get(opts, :concurrency, @default_concurrency),
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      rank_min:
        Keyword.get(
          opts,
          :rank_min,
          Application.get_env(:queue_of_matchmaking, :rank_min, 0)
        ),
      rank_max:
        Keyword.get(
          opts,
          :rank_max,
          Application.get_env(:queue_of_matchmaking, :rank_max, 10_000)
        ),
      mode: normalize_mode(Keyword.get(opts, :mode, "balanced_pairs"))
    }
  end

  defp normalize_mode("balanced_pairs"), do: :balanced_pairs
  defp normalize_mode("uniform"), do: :uniform
  defp normalize_mode("no_match"), do: :no_match
  defp normalize_mode(_), do: :balanced_pairs

  defp new_state(%{
         url: url,
         rps: rps,
         duration_s: duration_s,
         concurrency: concurrency,
         tick_ms: tick_ms,
         rank_min: rank_min,
         rank_max: rank_max,
         mode: mode
       }) do
    %{
      url: url,
      rps: rps,
      duration_s: duration_s,
      concurrency: concurrency,
      tick_ms: tick_ms,
      rank_min: rank_min,
      rank_max: rank_max,
      mode: mode,
      match_times: :ets.new(:load_test_match_times, [:bag, :public]),
      match_count: :counters.new(1, [:write_concurrency])
    }
  end

  # -----------------------
  # Core load loop
  # -----------------------

  defp run_load(state) do
    total_requests = state.rps * state.duration_s
    ticks = div(state.duration_s * 1000, state.tick_ms)

    base = div(total_requests, max(ticks, 1))
    remainder = rem(total_requests, max(ticks, 1))

    {elapsed_us, results} =
      :timer.tc(fn ->
        Enum.reduce(1..ticks, new_results(), fn tick_idx, acc ->
          tick_deadline_ms = System.monotonic_time(:millisecond) + state.tick_ms

          # First 'remainder' ticks get base+1, rest get base
          per_tick = if tick_idx <= remainder, do: base + 1, else: base

          batch = build_batch(state, tick_idx, per_tick)

          acc =
            batch
            |> Task.async_stream(&send_one(state.url, &1),
              max_concurrency: state.concurrency,
              timeout: 30_000,
              ordered: false
            )
            |> Enum.reduce(acc, &accumulate_result/2)

          sleep_until(tick_deadline_ms)
          acc
        end)
      end)

    {div(elapsed_us, 1000), results}
  end

  defp sleep_until(deadline_ms) do
    now_ms = System.monotonic_time(:millisecond)
    remaining = deadline_ms - now_ms

    if remaining > 0 do
      Process.sleep(remaining)
    end

    :ok
  end

  # -----------------------
  # Batch generation
  # -----------------------

  defp build_batch(state, tick_idx, n) do
    base = (tick_idx - 1) * n

    Enum.map(0..(n - 1), fn i ->
      seq = base + i
      build_request(state, seq)
    end)
  end

  # Modes:
  # - :balanced_pairs => ranks in pairs (x, x+1) to encourage fast matching
  # - :uniform => ranks uniform random across range (queue growth stress)
  # - :no_match => ranks spaced far apart to prevent matching (queue buildup)
  defp build_request(%{mode: :balanced_pairs} = state, seq) do
    rank = paired_rank(state, seq)
    user_id = "u#{seq}"
    %{user_id: user_id, rank: rank}
  end

  defp build_request(%{mode: :uniform} = state, seq) do
    rank = uniform_rank(state, seq)
    user_id = "u#{seq}"
    %{user_id: user_id, rank: rank}
  end

  defp build_request(%{mode: :no_match} = state, seq) do
    rank = no_match_rank(state, seq)
    user_id = "u#{seq}"
    %{user_id: user_id, rank: rank}
  end

  defp paired_rank(%{rank_min: min, rank_max: max}, seq) do
    span = max - min + 1
    base = rem(div(seq, 2), span)
    min + base + rem(seq, 2)
  end

  defp uniform_rank(%{rank_min: min, rank_max: max}, seq) do
    span = max - min + 1
    # deterministic pseudo-random-ish without calling :rand a million times
    v = :erlang.phash2(seq, span)
    min + v
  end

  defp no_match_rank(%{rank_min: min, rank_max: max}, seq) do
    span = max - min + 1
    # Space requests 200 ranks apart (beyond typical widening)
    spacing = 200
    clusters = div(span, spacing)
    cluster = rem(seq, max(clusters, 1))
    min + cluster * spacing
  end

  # -----------------------
  # HTTP client (Erlang :httpc)
  # -----------------------

  defp send_one(url, %{user_id: user_id, rank: rank}) do
    t0 = System.monotonic_time(:microsecond)

    body =
      %{
        "query" => mutation_query(),
        "variables" => %{"userId" => user_id, "rank" => rank}
      }
      |> Jason.encode!()

    headers = [{~c"content-type", ~c"application/json"}]
    request = {to_charlist(url), headers, ~c"application/json", body}

    result =
      case :httpc.request(:post, request, httpc_opts(), []) do
        {:ok, {{_version, status, _reason_phrase}, _headers, resp_body}} when status in 200..299 ->
          parse_ok(resp_body)

        {:ok, {{_version, status, _reason_phrase}, _headers, _resp_body}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end

    t1 = System.monotonic_time(:microsecond)
    latency_ms = div(t1 - t0, 1000)

    {latency_ms, result}
  end

  defp httpc_opts do
    [
      timeout: 5_000,
      connect_timeout: 2_000
    ]
  end

  defp mutation_query do
    "mutation Add($userId: String!, $rank: Int!) { addRequest(userId: $userId, rank: $rank) { ok error } }"
  end

  defp parse_ok(resp_body) do
    with {:ok, decoded} <- Jason.decode(to_string(resp_body)),
         %{"data" => %{"addRequest" => %{"ok" => true}}} <- decoded do
      :ok
    else
      {:ok, %{"data" => %{"addRequest" => %{"ok" => false, "error" => err}}}} ->
        {:error, {:rejected, err}}

      {:ok, other} ->
        {:error, {:unexpected, other}}

      {:error, reason} ->
        {:error, {:bad_json, reason}}

      other ->
        {:error, {:unexpected, other}}
    end
  end

  # -----------------------
  # Results aggregation
  # -----------------------

  defp new_results do
    %{
      total: 0,
      ok: 0,
      error: 0,
      rejected: 0,
      latency_samples: [],
      latency_sample_size: 0,
      latency_sample_limit: 100_000
    }
  end

  defp accumulate_result({:ok, {latency_ms, :ok}}, acc) do
    acc
    |> inc(:total)
    |> inc(:ok)
    |> push_latency(latency_ms)
  end

  defp accumulate_result({:ok, {latency_ms, {:error, {:rejected, _}}}}, acc) do
    acc
    |> inc(:total)
    |> inc(:error)
    |> inc(:rejected)
    |> push_latency(latency_ms)
  end

  defp accumulate_result({:ok, {latency_ms, {:error, _}}}, acc) do
    acc
    |> inc(:total)
    |> inc(:error)
    |> push_latency(latency_ms)
  end

  defp accumulate_result({:exit, _reason}, acc) do
    acc
    |> inc(:total)
    |> inc(:error)
  end

  defp inc(map, key), do: Map.update!(map, key, &(&1 + 1))

  defp push_latency(
         %{latency_sample_size: size, latency_sample_limit: limit} = acc,
         ms
       )
       when size < limit do
    %{acc | latency_samples: [ms | acc.latency_samples], latency_sample_size: size + 1}
  end

  defp push_latency(acc, _ms), do: acc

  # -----------------------
  # Reporting
  # -----------------------

  defp report(state, elapsed_ms, results, before_mem, after_mem) do
    latencies = Enum.sort(results.latency_samples)
    {p50, p95, p99} = percentile_triplet(latencies)

    elapsed_s = elapsed_ms / 1000.0
    rps_actual = if elapsed_s > 0, do: results.total / elapsed_s, else: 0.0

    {_match_avg, _match_p95, _match_p99, _match_count} = match_time_stats(state)

    mem_delta = after_mem.total - before_mem.total

    IO.puts("""
    Results
      Total requests: #{results.total}
      Requests/second: #{Float.round(rps_actual, 2)}
      HTTP latency ms:
        p50: #{p50}
        p95: #{p95}
        p99: #{p99}
      Errors: #{results.error} (rejected: #{results.rejected})
      Memory total bytes:
        before: #{before_mem.total}
        after:  #{after_mem.total}
        delta:  #{mem_delta}
    """)
  end

  defp percentile_triplet([]), do: {0, 0, 0}

  defp percentile_triplet(sorted) do
    {pct(sorted, 50), pct(sorted, 95), pct(sorted, 99)}
  end

  defp pct(sorted, p) when is_list(sorted) and p in [50, 95, 99] do
    n = length(sorted)
    idx = percent_index(n, p)
    Enum.at(sorted, idx) || 0
  end

  defp percent_index(n, p) do
    # nearest-rank method
    raw = Float.ceil(n * (p / 100.0)) |> trunc()
    max(min(raw - 1, n - 1), 0)
  end

  defp match_time_stats(state) do
    match_ms =
      state.match_times
      |> :ets.lookup(:match_ms)
      |> Enum.map(fn {:match_ms, v} -> v end)
      |> Enum.sort()

    count = :counters.get(state.match_count, 1)

    avg =
      case match_ms do
        [] -> 0
        _ -> div(Enum.sum(match_ms), length(match_ms))
      end

    {avg, pct(match_ms, 95), pct(match_ms, 99), count}
  end

  defp snapshot_memory do
    %{total: :erlang.memory(:total)}
  end
end
