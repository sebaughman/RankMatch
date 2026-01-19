# Architecture: Partition & Node Management

This document describes how the system manages clusters, partition assignments, and node join/leave events.

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    Partition & Node Management Flow                       │
└──────────────────────────────────────────────────────────────────────────┘

                         ┌─────────────────┐
                         │  Cluster Event  │
                         │  (Node Up/Down) │
                         └────────┬────────┘
                                  │
                                  ▼
                    ┌──────────────────────────┐
                    │      Membership          │
                    │  (Monitors :net_kernel)  │
                    └──────────┬───────────────┘
                               │
                               │ Detects node join/leave
                               │
                    ┏━━━━━━━━━━┻━━━━━━━━━━┓
                    ▼                      ▼
        ┌───────────────────┐   ┌──────────────────────┐
        │  Update Horde     │   │ Trigger Coordinator  │
        │  Membership       │   │      Refresh         │
        │                   │   │                      │
        │ - Registry        │   └──────────┬───────────┘
        │ - Supervisor      │              │
        └───────────────────┘              │
                                           ▼
                              ┌─────────────────────────┐
                              │ AssignmentCoordinator   │
                              │                         │
                              │ 1. Get sorted node list │
                              │ 2. Compute assignments  │
                              │ 3. Build snapshot       │
                              │ 4. Broadcast update     |
                              |      (only leader)      │
                              └────────┬────────────────┘
                                       │
                                       │ {:assignments_updated, snapshot}
                                       │ (via PubSub)
                                       │
                    ┏━━━━━━━━━━━━━━━━━━┻━━━━━━━━━━━━━━━━━━┓
                    ▼                                      ▼
        ┌───────────────────────┐            ┌────────────────────────┐
        │   PartitionManager    │            │       Router           │
        │                       │            │                        │
        │ 1. Filter local       │            │ 1. Build routing table │
        │    assignments        │            │ 2. Store in            │
        │ 2. Diff with current  │            │    :persistent_term    │
        │ 3. Start missing      │            │ 3. Update epoch        │
        │ 4. Stop extra         │            └────────────────────────┘
        └───────┬───────────────┘
                │
                │ Start/Stop partition workers
                │
                ▼
    ┌───────────────────────────┐
    │   Horde.Supervisor        │
    │                           │
    │ - start_child()           │
    │ - terminate_child()       │
    └───────┬───────────────────┘
            │
            │ Spawns/Terminates
            ▼
    ┌───────────────────────────┐
    │   PartitionWorker         │
    │   (GenServer)             │
    │                           │
    │ - Registered in           │
    │   Horde.Registry          │
    │ - Key: {:partition,       │
    │         epoch, id}        │
    └───────────────────────────┘
```