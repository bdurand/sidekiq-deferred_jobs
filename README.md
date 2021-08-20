[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)

# Sidekiq Deferred Job

This gem provides an enhancement to [Sidekiq](https://github.com/mperham/sidekiq) to allow deferring enqueuing jobs until the end of a block. This can be used to better coordinate when jobs are enqueued.

This can be useful, for instance, if you have a block of code that enqueues jobs, but you want to prevent those jobs from running until all of the code has finished executing. This can help prevent race conditions when dealing with external services, or to prevent duplicate jobs from being enqueued.

For duplicate job supression, this gem supports both the [sidekiq-unique-jobs](https://github.com/mhenrixon/sidekiq-unique-jobs) as well as [Sidekiq Enterprise](https://github.com/mperham/sidekiq/wiki/Ent-Unique-Jobs).

There is no affect on scheduled jobs.

## Usage

Calling `Sidekiq.defer_jobs` with a block will prevent any workers from being immediately enqueued within the block.

```ruby
Sidekiq.defer_jobs do
  MyWorker.perform_async(1)
  # The MyWorker job will not be enqueued yet
end
# Only once we get to here will the MyWorker job be enqueued.
```

You can provide worker classes in the the argument to `Sidekiq.defer_jobs` to filter on which workers will be deferred.

You can also provide a hash which will be compared against the worker `sidekiq_options` to filter which workers will be deferred. Any worker that has the same keys and values defined in their `sidekiq_options` will be deferred.

Finally, you can pass `false` to turn off deferral sent in an outer block.

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
