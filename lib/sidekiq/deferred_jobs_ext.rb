# frozen_string_literal: true

# This file patches Sidekiq classes to add deferred job functionality.
# It's separate from the main file to avoid YARD documentation warnings
# for external gem classes.

Sidekiq.extend(Sidekiq::DeferredJobs::DeferBlock)

if defined?(Sidekiq::Job)
  Sidekiq::Job::ClassMethods.prepend(Sidekiq::DeferredJobs::DeferredWorker)
  Sidekiq::Job::Setter.prepend(Sidekiq::DeferredJobs::DeferredSetter)
else
  Sidekiq::Worker::ClassMethods.prepend(Sidekiq::DeferredJobs::DeferredWorker)
  Sidekiq::Worker::Setter.prepend(Sidekiq::DeferredJobs::DeferredSetter)
end
