# Sidekiq Deferred Jobs

[![Continuous Integration](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml)
[![Regression Test](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/regression_test.yml/badge.svg)](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/regression_test.yml)
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
