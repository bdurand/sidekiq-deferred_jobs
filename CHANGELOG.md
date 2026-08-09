# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.1.0

### Fixed

- Scheduled jobs enqueued through a `Setter` (i.e. `MyWorker.set(queue: "high").perform_in(60)` or `MyWorker.set(wait: 60).perform_async`) are no longer deferred. This matches the existing behavior of `MyWorker.perform_in` since scheduled jobs are not enqueued to run immediately anyway.
- Added missing `require "set"` which could cause a `NameError` when deferred jobs were enqueued on Ruby < 3.2 in applications that did not already load the set library.
- Deferred jobs that have not yet been enqueued are no longer silently dropped if an error is raised while enqueuing jobs. The error is still raised to the calling code, but the remaining jobs are retained so `Sidekiq.enqueue_deferred_jobs!` can be safely retried.
- Duplicate unique jobs are no longer suppressed if they are enqueued to different queues.
- Runtime options are no longer lost when a job is passed through `Sidekiq::DeferredJobs.defer_worker` outside of a defer block.

### Added

- Deferred jobs are now persisted to Redis while they are deferred, so they are not lost if a process crashes or is killed inside a `defer_jobs` block. When a block is flushed, its jobs are atomically moved to an in-flight list in Redis and are removed only after they have been handed to Sidekiq, so a crash at any point during the flush cannot lose a job (delivery is at least once). Orphaned jobs left behind by a dead process are reaped and enqueued by a later flush in any process. When Sidekiq is running in a testing mode, deferred jobs continue to be held in memory.
- Consecutive deferred jobs that share a worker class and the same options are enqueued with a single Sidekiq bulk push, and jobs are acknowledged in Redis in groups of up to 100. A block that defers many jobs of the same kind therefore costs about one Redis round trip per job, which is what enqueuing the jobs directly would have cost. Because acknowledgement is batched, a crash in the middle of a flush can repeat a group of jobs rather than a single job.
- Each process scans for orphaned batches at most once per grace period instead of on every flush, so a single request can no longer be made to enqueue the jobs of many abandoned batches.
- Reaped jobs that cannot be enqueued (for example, when the worker class is not defined in the reaping process, or enqueuing repeatedly raises an error) are retried on later flushes instead of being dropped, and are moved to a dead list in Redis after too many failed attempts. An error enqueuing a reaped orphan job is contained and cannot break the flush of the block that reaped it.
- Added configuration options `Sidekiq::DeferredJobs.grace_period`, `.redis_key_prefix`, `.max_orphans_per_flush`, `.orphan_ttl`, and `.max_enqueue_attempts`.
- Added `Sidekiq::DeferredJobs.dead_jobs` and `Sidekiq::DeferredJobs.retry_dead_jobs!` to inspect and replay jobs on the dead list.

### Changed

- Filters passed to `Sidekiq.defer_jobs`, `Sidekiq.abort_deferred_jobs!`, and `Sidekiq.enqueue_deferred_jobs!` now raise an `ArgumentError` if they are not classes, modules, or hashes. Previously invalid filter values would silently match all jobs.

## 1.0.1

### Changed

- Update code to override Sidekiq::Job if it is defined, otherwise override Sidekiq::Worker. This doesn't impact functionality, but is more compatible with modern Sidekiq versions since Sidekiq::Worker is discouraged since version 6.3.

## 1.0.0

### Added

- Add behavior to Sidekiq to allow deferring enqueing jobs until after a block of code finishes.
