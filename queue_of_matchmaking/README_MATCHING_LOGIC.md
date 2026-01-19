# Architecture: Matching & Widening Logic

This document describes the matchmaking algorithm, including immediate matching, time-based widening, and cross-partition matching.

## Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      Matching & Widening Flow                             │
└──────────────────────────────────────────────────────────────────────────┘

    User Enqueues
    (rank: 1500)
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│              IMMEDIATE MATCH ATTEMPT                            │
│                                                                 │
│  allowed_diff = immediate_match_allowed_diff (100)              │
│                                                                 │
│  Search local partition for best opponent:                     │
│  - Within rank ± 100                                           │
│  - Closest rank wins                                           │
│  - No cross-partition search                                   │
└────────────────────┬────────────────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          │                     │
     Match Found?          No Match
          │                     │
          ▼                     ▼
    ┌──────────┐         ┌─────────────┐
    │ MATCHED  │         │  ENQUEUED   │
    │ (Instant)│         │ to partition|
    |          |         |      Queue  │
    └──────────┘         └──────┬──────┘
                                │
                                │ Ticket: {user_id, rank, enqueue_time}
                                │
                                ▼
                    ┌───────────────────────┐
                    │   WAITING IN QUEUE    │
                    │                       │
                    │  Every tick_interval  │
                    │  (100ms default)      │
                    └───────────┬───────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────────┐
│                    TICK-BASED MATCHING                            │
│                                                                   │
│  For each queued ticket (oldest first):                           │
│                                                                   │
│  1. Calculate age: age_ms = now - enqueue_time                    │
│                                                                   │
│  2. Calculate allowed_diff (WIDENING):                            │
│   allowed_diff = (age_ms / widening_step_ms) * widening_step_diff |
│     capped at widening_cap                                        │
│                                                                   │
│     Example (age = 300ms):                                        │
│     allowed_diff = (300 / 50) * 150 = 900 ranks                   │
│                                                                   │
│  3. Search for best opponent:                                    │
│     ┌─────────────────────────────────────────────┐              │
│     │  LOCAL PARTITION SEARCH                     │              │
│     │  - Search ranks within ± allowed_diff       │              │
│     │  - Max scan: max_scan_ranks (100)           │              │
│     │  - Find closest rank                        │              │
│     └─────────────────┬───────────────────────────┘              │
│                       │                                          │
│                       ▼                                          │
│     ┌─────────────────────────────────────────────┐              │
│     │  CROSS-PARTITION SEARCH                     │              │
│     │  (if allowed_diff crosses boundaries)       │              │
│     │                                             │              │
│     │  - Peek left neighbor partition             │              │
│     │  - Peek right neighbor partition            │              │
│     │  - RPC timeout: rpc_timeout_ms (100ms)      │              │
│     │  - Find closest across adjacent partitions  │              │
│     └─────────────────┬───────────────────────────┘              │
│                       │                                          │
│                       ▼                                          │
│     ┌─────────────────────────────────────────────┐              │
│     │  BEST PAIR SELECTION                        │              │
│     │                                             │              │
│     │  Compare all candidates:                    │              │
│     │  - Local opponent                           │              │
│     │  - Left partition opponent                  │              │
│     │  - Right partition opponent                 │              │
│     │                                             │              │
│     │  Choose closest rank difference             │              │
│     └─────────────────┬───────────────────────────┘              │
│                       │                                          │
└───────────────────────┼──────────────────────────────────────────┘
                        │
             ┌──────────┴──────────┐
             │                     │
        Match Found?          No Match
             │                     │
             ▼                     ▼
    ┌────────────────┐      ┌─────────────┐
    │  RESERVE       │      │ Continue    │
    │  OPPONENT      │      │ Waiting     │
    │                │      │             │
    │ - Local: dequeue      │ Next tick   │
    │ - Remote: RPC  │      │ (wider      │
    │   reserve()    │      │  search)    │
    └────────┬───────┘      └─────────────┘
             │
             ▼
    ┌────────────────┐
    │ FINALIZE MATCH │
    │                │
    │ - Release both │
    │   from UserIndex
    │ - Publish      │
    │   notification │
    └────────────────┘
```

