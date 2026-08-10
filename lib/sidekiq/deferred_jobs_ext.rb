# frozen_string_literal: true

# This file patches Sidekiq classes to add deferred job functionality.
# It's separate from the main file to avoid YARD documentation warnings
# for external gem classes.

Sidekiq.extend(Sidekiq::DeferredJobs::DeferBlock)

# Sidekiq::Job is the job mixin on Sidekiq 6.3+, but older versions define an
# unrelated Sidekiq::Job class in sidekiq/api.rb, so check for the mixin's
# ClassMethods constant rather than just the presence of the Sidekiq::Job constant.
if defined?(Sidekiq::Job) && Sidekiq::Job.const_defined?(:ClassMethods)
  Sidekiq::Job::ClassMethods.prepend(Sidekiq::DeferredJobs::DeferredWorker)
  Sidekiq::Job::Setter.prepend(Sidekiq::DeferredJobs::DeferredSetter)
else
  Sidekiq::Worker::ClassMethods.prepend(Sidekiq::DeferredJobs::DeferredWorker)
  Sidekiq::Worker::Setter.prepend(Sidekiq::DeferredJobs::DeferredSetter)
end
