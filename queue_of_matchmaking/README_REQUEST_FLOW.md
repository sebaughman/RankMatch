# Architecture: GraphQL Request Flow

This document describes the complete request/response flow from a GraphQL mutation through to the PartitionWorker and back to the client.

## Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         GraphQL Request Flow                             │
└─────────────────────────────────────────────────────────────────────────┘

    Client
      │
      │ mutation { addRequest(userId: "Player123", rank: 1500) }
      ▼
┌─────────────────┐
│  GraphQL Layer  │
│   (Resolvers)   │
└────────┬────────┘
         │
         │ 1. Validate input (userId, rank)
         ▼
┌─────────────────┐
│   UserIndex     │◄──────────────────────────────────┐
│  (Claim/Release)│                                   │
└────────┬────────┘                                   │
         │                                            │
         │ 2. Claim user (duplicate prevention)      │
         │    - Returns :ok or {:error, :already_queued}
         ▼                                            │
┌─────────────────┐                                   │
│     Router      │                                   │
│ (Route Lookup)  │                                   │
└────────┬────────┘                                   │
         │                                            │
         │ 3. route_with_epoch(rank)                 │
         │    - Lookup partition from :persistent_term
         │    - Validate epoch matches current       │
         │    - Returns {:ok, route} or error        │
         ▼                                            │
┌─────────────────┐                                   │
│ Horde.Registry  │                                   │
│  (PID Lookup)   │                                   │
└────────┬────────┘                                   │
         │                                            │
         │ 4. lookup({:partition, epoch, partition_id})
         │    - Returns partition worker PID         │
         ▼                                            │
┌─────────────────────────────────────────┐           │
│         PartitionWorker                 │           │
│                                         │           │
│  ┌───────────────────────────────────┐ │           │
│  │ 5. Enqueue Call (GenServer.call)  │ │           │
│  └───────────────┬───────────────────┘ │           │
│                  │                     │           │
│                  ▼                     │           │
│  ┌───────────────────────────────────┐ │           │
│  │ 6. Validate Epoch                 │ │           │
│  │    - Check request epoch == state │ │           │
│  │    - Return :stale_epoch if not   │ │           │
│  └───────────────┬───────────────────┘ │           │
│                  │                     │           │
│                  ▼                     │           │
│  ┌───────────────────────────────────┐ │           │
│  │ 7. Backpressure Check             │ │           │
│  │    - message_queue_len limit      │ │           │
│  │    - queued_count limit           │ │           │
│  │    - Return :overloaded if over   │ │           │
│  └───────────────┬───────────────────┘ │           │
│                  │                     │           │
│                  ▼                     │           │
│  ┌───────────────────────────────────┐ │           │
│  │ 8. Validate Rank in Range         │ │           │
│  │    - Check rank in partition range│ │           │
│  │    - Return :out_of_range if not  │ │           │
│  └───────────────┬───────────────────┘ │           │
│                  │                     │           │
│                  ▼                     │           │
│  ┌───────────────────────────────────┐ │           │
│  │ 9. Attempt Immediate Match        │ │           │
│  │    - allowed_diff = immediate_    │ │           │
│  │      match_allowed_diff (100)     │ │           │
│  │    - Search for best opponent     │ │           │
│  │      within allowed_diff          │ │           │
│  └───────────────┬───────────────────┘ │           │
│                  │                     │           │
│         ┌────────┴────────┐            │           │
│         │                 │            │           │
│    Match Found?      No Match          │           │
│         │                 │            │           │
│         ▼                 ▼            │           │
│  ┌─────────────┐   ┌─────────────┐    │           │
│  │ Dequeue     │   │ Enqueue     │    │           │
│  │ Opponent    │   │ Ticket      │    │           │
│  │             │   │ to Queue    │    │           │
│  │ Finalize    │   │             │    │           │
│  │ Match       │   │ Return :ok  │    │           │
│  └──────┬──────┘   └────────────-┘    │           │
│         │                             │           │
│         │                             │           │
└─────────┼─────────────────────────────┘           │
          │                                         │
          │                                         │
          ▼                                         │
    ┌─────────────────────────────┐                 │
    │  Release UserIndex          │──────────────────┘
    │  (both users if matched)    │
    └─────────────┬───────────────┘
                  │
                  ▼
    ┌─────────────────────────────┐
    │  Publish Match Notification │
    │  (if matched)               │
    └─────────────┬───────────────┘
                  │
                  ▼
    ┌─────────────────────────────┐
    │  Return Response to Client  │
    │  {ok: true/false, error: ?} │
    └─────────────────────────────┘
```
