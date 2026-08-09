# Sidekiq Deferred Jobs

[![Continuous Integration](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-deferred_jobs.svg)](https://badge.fury.io/rb/sidekiq-deferred_jobs)

This gem provides an enhancement to [Sidekiq](https://github.com/mperham/sidekiq) to defer enqueuing jobs until the end of a block of code. This is useful in situations where you need to better coordinate when jobs are enqueued to guard against race conditions or deduplicate jobs. In most cases, this provides no functional difference to your code; it just delays slightly when jobs are enqueued.

## Usage

If you have a complex operation composed of several discrete service objects that each fire off Sidekiq jobs, but you need to coordinate when those jobs are actually run, you could use this code to do so. This might be to avoid race condition where you don't want some jobs running until the entire operation is finished or because some of the code fires off duplicate jobs that you'd like to squash. If you have a worker that automatically fires on data updates to send synchronization messages to another systems, you might want to have only a single job run at the end of the all the updates rather than sending multiple updates within a few milliseconds. This gem is designed to give you control over that situation rather than having to refactor code that may have side effects in other situations.

If you are using either [the sidekiq-unique-jobs gem](https://github.com/mhenrixon/sidekiq-unique-jobs) or [Sidekiq Enterprise unique jobs](https://github.com/mperham/sidekiq/wiki/Ent-Unique-Jobs), then unique jobs equeued in the deferred jobs block will be suppressed. This is useful since Sidekiq can be so fast that duplicate jobs can be picked up by worker threads almost instataneously so the system never detects that duplicate jobs were being enqueued.

Using the scheduled jobs mechanism in Sidekiq to accomplish the same thing is less than ideal because the scheduling mechanism in Sidekiq is not designed to be very precise. If you schedule a job to run one second in the future, it might not run for several seconds.

Normally, Sidekiq will enqueue jobs immediately.

```ruby
ids.each do |id|
  SomeWorker.perform_async(id)
  # Each SomeWorker job is enqueued here
end
```

Calling `Sidekiq.defer_jobs` with a block prevents any workers from being immediately enqueued within the block.

```ruby
Sidekiq.defer_jobs do
  ids.each do |id|
    SomeWorker.perform_async(id)
    # SomeWorker jobs will not be enqueued here
  end
end
# All the jobs are now enqueued
```

The workers are fired in an `ensure` block, so even if an error is raised, any jobs that would have been enqueued prior to the error will still be enqueued.

You can also pass a filter to `defer_jobs` to filter either by class or by `sidekiq_options`.

```ruby
class SomeWorker
  include Sidekiq::Worker
  sidekiq_options priority: "high"
end

class OtherWorker
  include Sidekiq::Worker
end

# Filter by worker class
Sidekiq.defer_jobs(SomeWorker) do
  SomeWorker.perform_async(1)
  # The SomeWorker job will not be enqueued yet

  OtherWorker.perform_async(2)
  # The OtherWorker job will be enqueued here since it doesn't match the filter
end
# The SomeWorker job will now be enqueued

# Filter by sidekiq_options
Sidekiq.defer_jobs(priority: "high") do
  SomeWorker.perform_async(3)
  # The SomeWorker job will not be enqueued yet

  OtherWorker.perform_async(4)
  # The OtherWorker job will be enqueued here since it doesn't match the filter
end
# The SomeWorker job will now be enqueued
```

You can also pass `false` to `Sidekiq.defer_jobs` turn off deferral entirely within a block.

```ruby
Sidekiq.defer_jobs(false) do
  SomeWorker.perform_async(1)
  # The SomeWorker job will be enqueued
end
```

You can also manually control over when deferred jobs are enqueued or even remove previously deferred jobs.

```ruby
Sidekiq.defer_jobs do
  SomeWorker.perform_async(1)

  # This will cancel SomeWorker.perform(1); it won't be enqueued
  Sidekiq.abort_deferred_jobs!

  SomeWorker.perform_async(2)
  # SomeWorker.perform(2) is not yet equeued

  Sidekiq.enqueue_deferred_jobs!
  # SomeWorker.perform(2) will now be be equeued
end
```

You can pass filters to the `Sidekiq.abort_deferred_jobs!` and `Sidekiq.enqueue_deferred_jobs!` methods if you want to enqueue or abort just specific jobs. These filters work the same as the fitlers to `Sidekiq.defer_jobs`.

Scheduled jobs (i.e. `perform_in`, `perform_at`, or setting the `at` option) are never deferred since they are not enqueued to run immediately anyway.

If an error is raised while the deferred jobs are being enqueued (for instance, if Redis is briefly unavailable), the error will be raised to the calling code. Any jobs that had not yet been enqueued when the error occurred will be retained in the deferred jobs list, so a call to `Sidekiq.enqueue_deferred_jobs!` can be safely retried from within the block without duplicating jobs that were already enqueued.

## Durability

While jobs are deferred they are persisted to Redis (using the same Redis that Sidekiq is configured with). This means that if a process crashes or is killed while inside a `defer_jobs` block, the deferred jobs are not lost.

Each deferred job is written to Redis as soon as it would have been enqueued. When the block finishes, a Lua script atomically moves the batch into an in-flight list, and each job is removed from that list only after it has been handed to Sidekiq. That same atomic operation also reaps any **orphaned** jobs — jobs that were left in Redis by a process that died before it could enqueue them — and enqueues them as well.

Delivery is therefore **at least once**: a job can never be silently lost, but if a process dies at exactly the wrong moment (after handing a job to Sidekiq but before acknowledging it in Redis), that one job can be enqueued a second time when it is later reaped as an orphan. Sidekiq itself has the same at-least-once semantics, so workers should be idempotent anyway.

A batch is considered orphaned once no job has been deferred to it for longer than the configurable grace period. The grace period should be comfortably longer than the longest gap you expect between deferring jobs inside a `defer_jobs` block. If a live block is quiet for longer than the grace period, another process can reap its batch and enqueue its jobs early. Orphan timestamps are taken from the Redis server clock, so clock skew between application hosts does not affect reaping.

Because any process sharing the Redis key prefix can reap an orphaned batch, the reaping process must be able to resolve the job's worker class by name. If it cannot (for example, during a rolling deploy where only new processes define a new worker class), the job is kept in Redis and retried on later flushes so a process that does define the class can enqueue it. After `max_enqueue_attempts` failed attempts (also counting jobs that repeatedly raise errors when enqueued), the job's payload is moved to the dead list at `<prefix>:dead`, where it expires after the `orphan_ttl`. If two independent applications share one Redis, give each application its own `redis_key_prefix`.

Because deferred jobs are serialized by class name, anonymous worker classes cannot be deferred and will raise an `ArgumentError`.

When Sidekiq is running in a testing mode (`Sidekiq::Testing.fake!` or `Sidekiq::Testing.inline!`), deferred jobs are held in memory instead of Redis, so your test suite does not need a running Redis just to use this gem.

### Configuration

```ruby
# Seconds of inactivity before an unflushed batch is treated as orphaned and eligible
# to be reaped by another process. Default: 300.
Sidekiq::DeferredJobs.grace_period = 300

# Redis key prefix used for all keys created by this gem. Default: "sidekiq-deferred_jobs".
Sidekiq::DeferredJobs.redis_key_prefix = "sidekiq-deferred_jobs"

# Maximum number of orphaned batches to reap on a single flush. Default: 100.
Sidekiq::DeferredJobs.max_orphans_per_flush = 100

# Backstop TTL (in seconds) applied to batch keys so batches that are never reaped still
# expire from Redis. Default: 86400 (24 hours).
Sidekiq::DeferredJobs.orphan_ttl = 86_400

# Number of times a reaped job that cannot be enqueued is retried on later flushes
# before its payload is moved to the dead list. Default: 5.
Sidekiq::DeferredJobs.max_enqueue_attempts = 5
```

## Limitations

- Only jobs enqueued with `perform_async` are deferred. Jobs enqueued through other mechanisms (`perform_bulk`, `Sidekiq::Client.push`, or ActiveJob with the Sidekiq adapter) are not intercepted and will be enqueued immediately.

- The list of deferred jobs is scoped to the current thread and fiber. Jobs enqueued from other threads or fibers spawned inside a `defer_jobs` block (including code using lazy enumerators or async frameworks that switch fibers) will not be deferred.

- The Lua scripts used by the Redis persistence derive key names at runtime, so this gem is not compatible with Redis Cluster (Sidekiq itself does not support Redis Cluster either).

Note that if you are running with a relational database you may want to use another mechanism to work with transactional data (i.e. the `after_commit` hook in ActiveRecord). However, if you have a single logical operation that contains multiple transactions, this mechanism could be a good fit. For example, if you have a complex business operation that updates multiple rows and calls external services, you may not want a single transaction since it could lock database rows for a long period creating performance problems. This gem could be used to orchestrate transactional logic for Sidekiq workers in systems with native transaction support.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'sidekiq-deferred_jobs'
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install sidekiq-deferred_jobs
```

## Contributing

Open a pull request on GitHub.

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
