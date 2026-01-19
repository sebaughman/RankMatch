# QueueOfMatchmaking

A distributed, matchmaking system.

## Quick Start

A few tests have intermitint failures and a few long running integration / load tests failing. TODO: fix these. 

### Running the Server

```bash
# Install dependencies
mix deps.get

# Start the server
mix phx.server
```

The server will start on `http://localhost:4000`. Access GraphiQL at `http://localhost:4000/graphiql`.

### Running Tests

```bash
mix test
```

## GraphQL API

### Add a Match Request

```graphql
mutation {
  addRequest(userId: "Player123", rank: 1500) {
    ok
    error
  }
}
```

**Response:**
```json
{
  "data": {
    "addRequest": {
      "ok": true,
      "error": null
    }
  }
}
```

### Subscribe to Match Notifications

```graphql
subscription {
  matchFound(userId: "Player123") {
    users {
      userId
      userRank
    }
  }
}
```

**Response (when matched):**
```json
{
  "data": {
    "matchFound": {
      "users": [
        {
          "userId": "Player123",
          "userRank": 1500
        },
        {
          "userId": "Player456",
          "userRank": 1480
        }
      ]
    }
  }
}
```

# Load Testing Guide

This project includes comprehensive load testing capabilities to measure matchmaking system performance under various conditions.

## Start

The load test runs as a **separate HTTP client** that connects to your running server. This provides accurate performance metrics without resource contention.

### 1. Start the Server (Terminal 1)

```bash
cd queue_of_matchmaking
mix phx.server
```

### 2. Run a Single Load Test (Terminal 2)

In another terminal:

```bash
cd queue_of_matchmaking
mix load_test --rps 10000 --duration_s 10 --mode balanced_pairs
```


## Architecture Overview

### Partitioning Strategy

The system divides the rank range (0-10,000) into **32 partitions** of ~312 ranks each (configurable). Each partition is managed by a dedicated worker process, enabling parallel processing and horizontal scalability.

- **Partition 0**: ranks 0-312
- **Partition 1**: ranks 313-625
- **Partition 31**: ranks 9688-10000

### Matching Logic

**Immediate Matching**: When a user enqueues, the system attempts an immediate match within the same partition with an allowed rank difference of up to 100 (configurable via `immediate_match_allowed_diff`).

**Gradual Widening**: If no immediate match is found, the system periodically expands the acceptable rank difference over time:
- Every 50ms, the allowed difference increases by 150 ranks
- Maximum difference capped at 2,000 ranks
- Ensures users eventually match while prioritizing close skill levels

### Cross-Partition Matching

Users near partition boundaries can match with users in adjacent partitions (or nodes in a dirstributed system). The system queries neighboring partitions during the widening phase to find the closest possible match across the entire rank range.

### Node Join/Leave Behavior

When nodes join or leave the cluster:
- **Automatic rebalancing**: Partitions are redistributed across available nodes
- **Partition restart**: Affected partitions restart on their new nodes
- **Ticket loss**: In-flight match requests in restarted partitions are lost (clients must re-enqueue)

This design prioritizes availability and simplicity over perfect state preservation.
TODO: warm up, migrate user tickets, tear down 

### Epoch Versioning

The system includes epoch-based versioning infrastructure (currently epoch=1) that provides the foundation for zero-downtime partition migrations allowing controlled cutover when adding/removing partitions or changing configuration.

## Configuration

Key parameters can be adjusted in `config/config.exs`:

- **Widening**: `widening_step_ms`, `widening_step_diff`, `widening_cap`
- **Backpressure**: `message_queue_limit`, `queued_count_limit`
- **Partitioning**: `partition_count`, `rank_min`, `rank_max`
