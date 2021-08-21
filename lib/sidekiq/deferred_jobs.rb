# frozen_string_literal: true

require "sidekiq"

module Sidekiq
  module DeferredJobs
    class << self
      # Defer enqueuing Sidekiq workers within the block until the end of the block.
      # Any workers that normally would have been enqueued with a `perform_async` call
      # will instead be queued up and run in an ensure clause at the end of the block.
      # @param filter [Array<Module>, Array<Hash>] An array of either classes, modules, or hashes.
      #        If this is provided, only workers that match either a class or module or which have
      #        sidekiq_options that match a hash will be deferred. All other worker will be enqueued as normal.
      # @return [void]
      def defer(filter, &block)
        jobs, filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        unless jobs
          filters = []
          jobs = Jobs.new
          Thread.current[:sidekiq_deferred_jobs_jobs] = [jobs, filters]
        end
        filters.push(Filter.new(filter))
        begin
          yield
        ensure
          filters.pop
          if filters.empty?
            Thread.current[:sidekiq_deferred_jobs_jobs] = nil
            jobs.enqueue!
          end
        end
      end

      # Disable deferred workers within the block. All workers will be enqueued normally
      # within the block.
      # @return [void]
      def undeferred(&block)
        save_val = Thread.current[:sidekiq_deferred_jobs_jobs]
        begin
          Thread.current[:sidekiq_deferred_jobs_jobs] = nil
          yield
        ensure
          Thread.current[:sidekiq_deferred_jobs_jobs] = save_val
        end
      end

      # Return true if the specified class with optional options should be deferred.
      # @param klass [Class] A Sidekiq worker class
      # @param opts [Hash, Nil] Optionsl options set at runtime for the worker.
      # @return Boolean
      def defer?(klass, opts = nil)
        _jobs, filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        return false if filters.nil?
        filters.any? { |filter| filter.match?(klass, opts) }
      end

      # Schedule a worker to be run at the end of the outermost defer block.
      # @param klass [Class] Sidekiq worker class
      # @param args [Array] Sidekiq job arguments
      # @param opts [Hash, Nil] Optional sidekiq options specified for the job
      # @return [void]
      def defer_worker(klass, args, opts = nil)
        jobs, _filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        if jobs
          jobs.defer(klass, args, opts)
        else
          klass.perform_async(*args)
        end
      end
    end

    module DeferBlock
      # Defer enqueuing Sidekiq workers within the block until the end of the block.
      # Any workers that normally would have been enqueued with a `perform_async` call
      # will instead be queued up and run in an ensure clause at the end of the block.
      # @param *filter [Module>, Hash, FalseClass] Optional filter on which workers should be deferred.
      #                If a filter is specified, only matching workers will be deferred. To match the
      #                filter, the worker must either be the class specfied or include the module or
      #                have sidekiq_options that match the specified hash. If the filter is `false`
      #                then job deferral will be disabled entirely within the block.
      # @return [void]
      def defer_jobs(*filter, &block)
        if filter.size == 1 && filter.first == false
          Sidekiq::DeferredJobs.undeferred(&block)
        else
          Sidekiq::DeferredJobs.defer(filter, &block)
        end
      end

      # Abort any already deferred Sidkiq workers in the current `defer_job` block.
      # If a filter is specified, then only matching Sidekiq jobs will be aborted.
      # @param *filter See #defer_job for filter specification.
      # @return [void]
      def abort_deferred_jobs!(*filter)
        jobs, _filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        if jobs
          jobs.clear!(filter)
        end
        nil
      end

      # Immediately enqueue any already deferred Sidkiq workers in the current `defer_job` block.
      # If a filter is specified, then only matching Sidekiq jobs will be enqueued.
      # @param *filter See #defer_job for filter specification.
      # @return [void]
      def enqueue_deferred_jobs!(*filter)
        jobs, _filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        if jobs
          Sidekiq::DeferredJobs.undeferred { jobs.enqueue!(filter) }
        end
        nil
      end
    end

    # Override logic for Sidekiq::Worker.
    module DeferredWorker
      def perform_async(*args)
        if Sidekiq::DeferredJobs.defer?(self)
          Sidekiq::DeferredJobs.defer_worker(self, args)
        else
          super
        end
      end
    end

    # Override logic for Sidekiq::Worker::Setter.
    module DeferredSetter
      def perform_async(*args)
        if Sidekiq::DeferredJobs.defer?(@klass, @opts)
          Sidekiq::DeferredJobs.defer_worker(@klass, args, @opts)
        else
          super
        end
      end
    end

    # Logic for filtering jobs by worker class and/or sidekiq_options.
    class Filter
      def initialize(filters)
        @filters = Array(filters).flatten
      end

      # @return [Boolean] true if the job matches the filters.
      def match?(klass, opts = nil)
        return true if @filters.empty?
        @filters.any? do |filter|
          if filter.is_a?(Module)
            klass <= filter
          elsif filter.is_a?(Hash)
            worker_options = (opts ? klass.sidekiq_options.merge(opts.transform_keys(&:to_s)) : klass.sidekiq_options)
            filter.all? { |key, value| worker_options[key.to_s] == value }
          else
            filter
          end
        end
      end
    end

    # Class for holding deferred jobs.
    class Jobs
      def initialize
        @jobs = []
      end

      # Add a job to the deferred job list.
      # @param klass [Class] Sidekiq worker class.
      # @param args [Array] Sidekiq job arguments
      # @param opts [Hash, Nil] optional runtime jobs options
      def defer(klass, args, opts = nil)
        @jobs << [klass, args, opts]
      end

      # Clear any deferred jobs that match the filter.
      # @filter [Array<Module>, Array<Hash>] Filter for jobs to clear
      def clear!(filters = nil)
        filter = Filter.new(filters)
        @jobs = @jobs.reject { |klass, _args, opts| filter.match?(klass, opts) }
      end

      # Enqueue any deferred jobs that match the filter.
      # @filter [Array<Module>, Array<Hash>] Filter for jobs to clear
      def enqueue!(filters = nil)
        filter = Filter.new(filters)
        remaining_jobs = []
        begin
          duplicates = Set.new
          @jobs.each do |klass, args, opts|
            if filter.match?(klass, opts)
              if unique_job?(klass, opts)
                next if duplicates.include?([klass, args])
                duplicates << [klass, args]
              end
              if opts
                klass.set(opts).perform_async(*args)
              else
                klass.perform_async(*args)
              end
            else
              remaining_jobs << [klass, args, opts]
            end
          end
        ensure
          @jobs = remaining_jobs
        end
      end

      private

      # @return [Boolean] true if the worker support a uniqueness constraint
      def unique_job?(klass, opts)
        enterprise_option = worker_options(klass, opts)["unique_for"] if defined?(Sidekiq::Enterprise)
        unique_jobs_option = worker_options(klass, opts)["lock"] if defined?(SidekiqUniqueJobs)

        if enterprise_option
          true
        elsif unique_jobs_option
          unique_jobs_option.to_s != "while_executing"
        else
          false
        end
      end

      # Merge runtime options with the worker class sidekiq_options.
      def worker_options(klass, opts)
        if opts
          klass.sidekiq_options.merge(opts.transform_keys(&:to_s))
        else
          klass.sidekiq_options
        end
      end
    end
  end
end

Sidekiq.extend(Sidekiq::DeferredJobs::DeferBlock)
Sidekiq::Worker::ClassMethods.prepend(Sidekiq::DeferredJobs::DeferredWorker)
Sidekiq::Worker::Setter.prepend(Sidekiq::DeferredJobs::DeferredSetter)
