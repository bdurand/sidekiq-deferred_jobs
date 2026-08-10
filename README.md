# Sidekiq Deferred Jobs

[![Continuous Integration](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-deferred_jobs.svg)](https://badge.fury.io/rb/sidekiq-deferred_jobs)

This gem provides an enhancement to [Sidekiq](https://github.com/sidekiq/sidekiq) to defer enqueuing jobs until the end of a block of code. This is useful in situations where you need to better coordinate when jobs are enqueued to guard against race conditions or deduplicate jobs. In most cases, this provides no functional difference to your code; it just delays slightly when jobs are enqueued.

## Usage

If you have a complex operation composed of several discrete service objects that each fire off Sidekiq jobs, but you need to coordinate when those jobs are actually run, you could use this code to do so. This might be to avoid a race condition where you don't want some jobs running until the entire operation is finished, or because some of the code fires off duplicate jobs that you'd like to squash. If you have a worker that automatically fires on data updates to send synchronization messages to other systems, you might want to have only a single job run at the end of all the updates rather than sending multiple updates within a few milliseconds. This gem is designed to give you control over that situation rather than having to refactor code that may have side effects in other situations.

If you are using either [the sidekiq-unique-jobs gem](https://github.com/mhenrixon/sidekiq-unique-jobs) or [Sidekiq Enterprise unique jobs](https://github.com/sidekiq/sidekiq/wiki/Ent-Unique-Jobs), then duplicate jobs deferred within the block will be collapsed into a single job when the block exits. A job is considered a duplicate if it has the same class, arguments, and queue as a job already enqueued by the same flush of deferred jobs. The collapse does not read the uniqueness mechanism's own lock configuration (i.e. `unique_args`, `lock_args`, or `unique_across_queues`); jobs that are duplicates only under those settings are all enqueued and the uniqueness mechanism resolves them when they are pushed. When jobs are collapsed, the first job and its runtime options are kept. This is useful since Sidekiq can be so fast that duplicate jobs can be picked up by worker threads almost instantaneously, so the system never detects that duplicate jobs were being enqueued. Jobs that do not declare a uniqueness constraint (`unique_for` for Sidekiq Enterprise, or `lock` for sidekiq-unique-jobs) are never collapsed; neither are jobs locked only `while_executing`.

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

The deferred jobs are enqueued from an `ensure` block, so even if an error is raised inside the block, any jobs that would have been enqueued prior to the error will still be enqueued.

You can also pass a filter to `defer_jobs` so that only some jobs are deferred. A filter can be a class, a module, or a hash of `sidekiq_options`. A job matches a class or module filter if the worker class is that class, a subclass of it, or includes that module. It matches a hash filter if all of the entries in the hash match the worker's `sidekiq_options` (including any options set at runtime with `set`). You can pass multiple filters; a job is deferred if it matches any of them.

```ruby
class SomeWorker
  include Sidekiq::Job
  sidekiq_options priority: "high"
end

class OtherWorker
  include Sidekiq::Job
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

Blocks can be nested. Deferred jobs are always enqueued at the end of the outermost block, and the filters from all of the enclosing blocks apply, so a job is deferred if it matches the filter on any block it is inside of.

```ruby
Sidekiq.defer_jobs(SomeWorker) do
  Sidekiq.defer_jobs(OtherWorker) do
    SomeWorker.perform_async(1)  # deferred by the outer block's filter
    OtherWorker.perform_async(2) # deferred by the inner block's filter
  end
  # Neither job is enqueued here; the inner block does not flush jobs.
end
# Both jobs are now enqueued
```

You can pass `false` to `Sidekiq.defer_jobs` to turn off deferral entirely within a block. This is mostly useful inside a `defer_jobs` block to opt a section of code back into enqueuing jobs immediately.

```ruby
Sidekiq.defer_jobs do
  SomeWorker.perform_async(1)
  # The SomeWorker job is deferred

  Sidekiq.defer_jobs(false) do
    OtherWorker.perform_async(2)
    # The OtherWorker job is enqueued immediately
  end
end
```

You can also manually control when deferred jobs are enqueued or even remove previously deferred jobs.

```ruby
Sidekiq.defer_jobs do
  SomeWorker.perform_async(1)

  # This will cancel SomeWorker.perform_async(1); it won't be enqueued
  Sidekiq.abort_deferred_jobs!

  SomeWorker.perform_async(2)
  # SomeWorker.perform_async(2) is not yet enqueued

  Sidekiq.enqueue_deferred_jobs!
  # SomeWorker.perform_async(2) has now been enqueued
end
```

You can pass filters to the `Sidekiq.abort_deferred_jobs!` and `Sidekiq.enqueue_deferred_jobs!` methods if you want to enqueue or abort just specific jobs. These filters work the same as the class, module, and hash filters for `Sidekiq.defer_jobs` (`false` is not supported here). `Sidekiq.abort_deferred_jobs!` returns the jobs it removed; both methods do nothing when called outside of a `defer_jobs` block.

Scheduled jobs (i.e. `perform_in`, `perform_at`, or setting the `at` option with `set`) are never deferred since they are not enqueued to run immediately anyway.

If an error is raised while deferred jobs are being enqueued (for instance, if Redis is briefly unavailable), the error will be raised to the calling code. Any jobs that had not yet been enqueued when the error occurred are retained in the deferred jobs list rather than being silently dropped. If the error came from an explicit call to `Sidekiq.enqueue_deferred_jobs!`, you can rescue it and call the method again to enqueue the remaining jobs without duplicating the ones that already made it to Redis.

## Limitations

- Only jobs enqueued with `perform_async` are deferred. Jobs enqueued through other mechanisms (`perform_bulk`, `Sidekiq::Client.push`, or ActiveJob with the Sidekiq adapter) are not intercepted and will be enqueued immediately.

- `perform_async` does not return a job id for a deferred job. The job id is not assigned until the job is actually enqueued, so any code that captures the return value of `perform_async` should not be run inside a `defer_jobs` block.

- The list of deferred jobs is stored in fiber-local storage. Jobs enqueued from other threads or fibers spawned inside a `defer_jobs` block (including code using lazy enumerators or async frameworks that switch fibers) will not be deferred.

- If an error is raised by the automatic flush at the end of the outermost `defer_jobs` block, any jobs that had not been enqueued yet are lost; there is no way to retry them since the deferred job list is no longer reachable at that point.

> [!IMPORTANT]
> Deferred jobs are not persisted to Redis within the `defer_jobs` block. If your application crashes or is force killed before the block completes, any jobs that were deferred will be lost. This is a tradeoff to avoid the performance overhead of persisting jobs to Redis when they are deferred.

> [!NOTE]
> If you are running with a relational database you may want to use another mechanism to work with transactional data (i.e. the `after_commit` hook in ActiveRecord). However, if you have a single logical operation that contains multiple transactions, this mechanism could be a good fit. For example, if you have a complex business operation that updates multiple rows and calls external services, you may not want a single transaction since it could lock database rows for a long period creating performance problems. This gem could be used to orchestrate transactional logic for Sidekiq workers in systems with native transaction support.

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

No further setup is required; requiring the gem patches Sidekiq automatically.

### Requirements

- Ruby 2.5 or later
- Sidekiq 5.0 or later

The examples in this README use `Sidekiq::Job`, which was added in Sidekiq 6.3. If you are on an older version of Sidekiq, use `Sidekiq::Worker` instead.

## Contributing

Open a pull request on GitHub.

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
