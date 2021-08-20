[![Continuous Integration](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-deferred_jobs/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)

# Sidekiq Deferred Job

This gem provides an enhancement to [Sidekiq](https://github.com/mperham/sidekiq) to defer enqueuing jobs until the end of a block of code. This can be used in situations where you need to better coordinate when jobs are enqueued.

If you have a complex operation composed of several discrete service objects that each fire off Sidekiq jobs, but you need to coordinate when those jobs are actually run, you could use this code to do so. This might be to avoid race condition where you don't want some jobs running until the entire operation is finished or because some of the code fires off duplicate jobs that you'd like to squash. For instance, if you have a worker that automatically fires on data updates to send synchronization messages to another systems, you might want to wait to schedule a single job rather than sending multiple updates within a few milliseconds.

If you are using either [sidekiq-unique-jobs](https://github.com/mhenrixon/sidekiq-unique-jobs) or [Sidekiq Enterprise unique jobs](https://github.com/mperham/sidekiq/wiki/Ent-Unique-Jobs), unique jobs equeued in the deferred jobs block will be suppressed. This can be useful when your uniqueness constraint is only for enqueued jobs. Sidekiq can be so fast that duplicate jobs can be picked up by worker threads almost instataneously.

Using the scheduled jobs mechanism in Sidekiq to accomplish the same thing is less than ideal because the scheduling mechanism in Sidekiq is not designed to be very precise. If you schedule a job to run one second in the future, it might not run for several seconds.

Note that if you are running with a relational database you may want to use another mechanism to work with transactional data (i.e. the `after_commit` hook in ActiveRecord). However, if you have a single logical operation that contains multiple transactions, this mechanism could be a good fit. For example, if you have a complex business operation that updates multiple rows and calls external services, you may not want a single transaction since it could lock database rows for a long period creating performance problems.

## Usage

Calling `Sidekiq.defer_jobs` with a block will prevent any workers from being immediately enqueued within the block.

```ruby
Sidekiq.defer_jobs do
  MyWorker.perform_async(1)
  # The MyWorker job will not be enqueued yet
end
# Only once we get to here will the MyWorker job be enqueued.
```

The workers will be fired in an `ensure` block, so even if an error is raised in the `defered_jobs` block, any jobs that would have been enqueued without deferral will still be enqueued.

You can also pass a filter to `defer_jobs` to filter either by class or by `sidekiq_options`.

```ruby
Sidekiq.defer_jobs(MyWorker) do
  MyWorker.perform_async(1)
  # The MyWorker job will not be enqueued yet

  OtherWorker.perform_async(2)
  # The OtherWorker job will be enqueued since it doesn't match the filter
end

Sidekiq.defer_jobs(priority: "high") do
  # Only workers with `sidekiq_options priority: "high"` will be deferred
end
```

You can also pass `false` to `defer_jobs` turn off deferral within a block.

```ruby
Sidekiq.defer_jobs(false) do
  MyWorker.perform_async(1)
  # The MyWorker job will be enqueued
end
```

If you need more control over when jobs are enqueued or even need to remove previously deferred jobs.

```ruby
Sidekiq.defer_jobs do
  MyWorker.perform_async(1)

  # This will cancel MyWorker.perform(1)
  Sidekiq.abort_deferred_jobs!

  MyWorker.perform_async(2)
  Sidekiq.enqueu_deferred_jobs!
  # MyWorker.perform(2) will now be equeued
end
```

You can also pass filters to the `Sidekiq.abort_deferred_jobs!` and `Sidekiq.enqueue_deferred_jobs!` methods if you want to enqueue or abort just specific jobs.

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
