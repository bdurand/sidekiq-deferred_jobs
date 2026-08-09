# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Deferred jobs are now persisted to Redis while they are deferred, so they are not lost if a process crashes or is killed inside a `defer_jobs` block. When a block is flushed, its jobs are atomically popped from Redis and any orphaned jobs left behind by a dead process are reaped and enqueued as well, using a single Lua script that guarantees each job is enqueued exactly once. When Sidekiq is running in a testing mode, deferred jobs continue to be held in memory.
- Added configuration options `Sidekiq::DeferredJobs.grace_period`, `.redis_key_prefix`, `.max_orphans_per_flush`, and `.orphan_ttl`.

## 1.0.2

### Fixed

- Scheduled jobs enqueued through a `Setter` (i.e. `MyWorker.set(queue: "high").perform_in(60)` or `MyWorker.set(wait: 60).perform_async`) are no longer deferred. This matches the existing behavior of `MyWorker.perform_in` since scheduled jobs are not enqueued to run immediately anyway.
- Added missing `require "set"` which could cause a `NameError` when deferred jobs were enqueued on Ruby < 3.2 in applications that did not already load the set library.
- Deferred jobs that have not yet been enqueued are no longer silently dropped if an error is raised while enqueuing jobs. The error is still raised to the calling code, but the remaining jobs are retained so `Sidekiq.enqueue_deferred_jobs!` can be safely retried.
- Duplicate unique jobs are no longer suppressed if they are enqueued to different queues.
- Runtime options are no longer lost when a job is passed through `Sidekiq::DeferredJobs.defer_worker` outside of a defer block.

### Changed

- Filters passed to `Sidekiq.defer_jobs`, `Sidekiq.abort_deferred_jobs!`, and `Sidekiq.enqueue_deferred_jobs!` now raise an `ArgumentError` if they are not classes, modules, or hashes. Previously invalid filter values would silently match all jobs.

## 1.0.1

### Changed

- Update code to override Sidekiq::Job if it is defined, otherwise override Sidekiq::Worker. This doesn't impact functionality, but is more compatible with modern Sidekiq versions since Sidekiq::Worker is discouraged since version 6.3.

## 1.0.0

### Added

- Add behavior to Sidekiq to allow deferring enqueing jobs until after a block of code finishes.
