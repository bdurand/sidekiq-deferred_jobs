# frozen_string_literal: true

require "set"
require "sidekiq"

module Sidekiq
  # Adds the ability to defer enqueuing Sidekiq jobs until the end of a block of code.
  # See Sidekiq::DeferredJobs::DeferBlock for the methods that are added to `Sidekiq`
  # itself (`Sidekiq.defer_jobs`, `Sidekiq.abort_deferred_jobs!`, and
  # `Sidekiq.enqueue_deferred_jobs!`).
  module DeferredJobs
    class << self
      # Defer enqueuing Sidekiq workers within the block until the end of the block.
      # Any workers that normally would have been enqueued with a `perform_async` call
      # will instead be queued up and run in an ensure clause at the end of the block.
      #
      # Blocks can be nested. Deferred jobs are only enqueued at the end of the outermost
      # block and the filters from all of the enclosing blocks apply, so a job is deferred
      # if it matches the filter on any block it is nested inside of.
      #
      # @param filter [Array<Module>, Array<Hash>] An array of either classes, modules, or hashes.
      #        If this is provided, only workers that match either a class or module or which have
      #        sidekiq_options that match a hash will be deferred. All other workers will be enqueued as normal.
      # @return [Object] the return value of the block
      def defer(filter, &block)
        new_filter = Filter.new(filter)
        jobs, filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        unless jobs
          filters = []
          jobs = Jobs.new
          Thread.current[:sidekiq_deferred_jobs_jobs] = [jobs, filters]
        end
        filters.push(new_filter)
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
      # within the block. Any jobs already deferred by an enclosing block are left alone
      # and will still be enqueued when that block exits.
      #
      # @return [Object] the return value of the block
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
      # Jobs scheduled to run in the future and jobs that run inline are never deferred.
      #
      # @param klass [Class] A Sidekiq worker class
      # @param opts [Hash, Nil] Optional options set at runtime for the worker.
      # @return [Boolean]
      def defer?(klass, opts = nil)
        return false if scheduled_opts?(opts) || inline_opts?(opts)
        _jobs, filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        return false if filters.nil?
        filters.any? { |filter| filter.match?(klass, opts) }
      end

      # Schedule a worker to be enqueued at the end of the outermost defer block.
      # If there is no defer block in progress, the worker is enqueued immediately.
      #
      # @param klass [Class] Sidekiq worker class
      # @param args [Array] Sidekiq job arguments
      # @param opts [Hash, Nil] Optional sidekiq options specified for the job
      # @return [void]
      def defer_worker(klass, args, opts = nil)
        jobs, _filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        if jobs
          jobs.defer(klass, args, opts)
        else
          enqueue_job(klass, args, opts)
        end
      end

      # Return true if the options indicate a job scheduled to run in the future.
      # Scheduled jobs are never deferred since they are not enqueued immediately anyway.
      #
      # @param opts [Hash, Nil] Runtime options set for a job.
      # @return [Boolean]
      # @api private
      def scheduled_opts?(opts)
        return false unless opts
        !!(opts["at"] || opts[:at])
      end

      # Return true if the options indicate a job that runs inline at the call site
      # rather than being pushed to a queue. Inline jobs are never deferred.
      #
      # @param opts [Hash, Nil] Runtime options set for a job.
      # @return [Boolean]
      # @api private
      def inline_opts?(opts)
        return false unless opts
        opts["sync"] == true || opts[:sync] == true
      end

      # Enqueue a job through the normal Sidekiq mechanism.
      #
      # @param klass [Class] Sidekiq worker class
      # @param args [Array] Sidekiq job arguments
      # @param opts [Hash, Nil] Optional runtime options for the job
      # @return [Object] the value returned by `perform_async`
      # @api private
      def enqueue_job(klass, args, opts = nil)
        if opts
          klass.set(opts).perform_async(*args)
        else
          klass.perform_async(*args)
        end
      end

      # Merge runtime options with the worker class sidekiq_options.
      #
      # @param klass [Class] Sidekiq worker class
      # @param opts [Hash, Nil] Optional runtime options for the job
      # @return [Hash] the merged options with string keys
      # @api private
      def worker_options(klass, opts = nil)
        if opts
          klass.sidekiq_options.merge(opts.transform_keys(&:to_s))
        else
          klass.sidekiq_options
        end
      end
    end

    # Methods added to the `Sidekiq` module itself for controlling deferred jobs.
    module DeferBlock
      # Defer enqueuing Sidekiq workers within the block until the end of the block.
      # Any workers that normally would have been enqueued with a `perform_async` call
      # will instead be queued up and run in an ensure clause at the end of the block.
      #
      # @param filter [Array<Module>, Hash, false] Optional filter on which workers should be deferred.
      #                If a filter is specified, only matching workers will be deferred. To match the
      #                filter, the worker must either be the class specified (or a subclass of it),
      #                include the module, or have sidekiq_options that match the specified hash.
      #                Multiple filters can be specified and a worker will be deferred if it matches
      #                any of them. If the filter is `false` then job deferral will be disabled
      #                entirely within the block.
      # @return [Object] the return value of the block
      def defer_jobs(*filter, &block)
        if filter.size == 1 && filter.first == false
          Sidekiq::DeferredJobs.undeferred(&block)
        else
          Sidekiq::DeferredJobs.defer(filter, &block)
        end
      end

      # Abort any already deferred Sidekiq workers in the current `defer_jobs` block.
      # If a filter is specified, then only matching Sidekiq jobs will be aborted.
      # Does nothing if called outside of a `defer_jobs` block.
      #
      # @param filter [Array<Module>, Hash] See #defer_jobs for filter specification.
      #                Unlike #defer_jobs, `false` is not a valid filter here.
      # @return [Array<Sidekiq::DeferredJobs::Job>] the jobs that were aborted
      def abort_deferred_jobs!(*filter)
        jobs, _filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        if jobs
          jobs.clear!(filter)
        else
          []
        end
      end

      # Immediately enqueue any already deferred Sidekiq workers in the current `defer_jobs` block.
      # If a filter is specified, then only matching Sidekiq jobs will be enqueued.
      # Does nothing if called outside of a `defer_jobs` block.
      #
      # @param filter [Array<Module>, Hash] See #defer_jobs for filter specification.
      #                Unlike #defer_jobs, `false` is not a valid filter here.
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
      # @return [Object] the job id if the job was enqueued. If the job was deferred, the
      #         return value is unspecified since no job id exists until the job is enqueued.
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
      # @return [Object] the job id if the job was enqueued. If the job was deferred, the
      #         return value is unspecified since no job id exists until the job is enqueued.
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
        @filters = (filters.is_a?(Hash) ? [filters] : Array(filters).flatten)
        invalid = @filters.reject { |filter| filter.is_a?(Module) || filter.is_a?(Hash) }
        unless invalid.empty?
          raise ArgumentError, "Filters must be classes, modules, or hashes; got #{invalid.collect(&:inspect).join(", ")}"
        end
      end

      # @return [Boolean] true if the job matches the filters.
      def match?(klass, opts = nil)
        return true if @filters.empty?
        @filters.any? do |filter|
          if filter.is_a?(Module)
            klass <= filter
          else
            worker_options = Sidekiq::DeferredJobs.worker_options(klass, opts)
            filter.all? { |key, value| worker_options[key.to_s] == value }
          end
        end
      end
    end

    # Data structure to hold job information.
    Job = Struct.new(:klass, :args, :opts)

    # Class for holding deferred jobs.
    class Jobs
      def initialize
        @jobs = []
        @dedup_keys = Set.new
      end

      # Add a job to the deferred job list.
      #
      # @param klass [Class] Sidekiq worker class.
      # @param args [Array] Sidekiq job arguments
      # @param opts [Hash, Nil] optional runtime jobs options
      # @return [void]
      def defer(klass, args, opts = nil)
        @jobs << Job.new(klass, args&.dup, opts&.dup)
      end

      # Clear any deferred jobs that match the filter.
      #
      # @param filters [Array<Module>, Array<Hash>] Filter for jobs to clear
      # @return [Array<Sidekiq::DeferredJobs::Job>] the jobs that were cleared
      def clear!(filters = nil)
        filter = Filter.new(filters)
        cleared_jobs = @jobs.select { |job| filter.match?(job.klass, job.opts) }
        @jobs -= cleared_jobs
        cleared_jobs
      end

      # Enqueue any deferred jobs that match the filter.
      #
      # If a worker declares a uniqueness constraint (either with Sidekiq Enterprise or the
      # sidekiq-unique-jobs gem), then duplicate jobs with the same class, arguments, and queue
      # are collapsed into a single job within this call.
      #
      # If enqueuing a job raises an error, the error will be propagated to the caller
      # and any jobs that have not yet been enqueued will be retained in the deferred
      # job list so they are not silently lost and can be enqueued again. The keys of
      # unique jobs that were already enqueued are remembered until a call completes
      # without an error so that retrying does not enqueue duplicates.
      #
      # @param filters [Array<Module>, Array<Hash>] Filter for jobs to enqueue
      # @return [void]
      def enqueue!(filters = nil)
        filter = Filter.new(filters)
        unmatched_jobs = []
        pending_jobs = @jobs
        begin
          until pending_jobs.empty?
            job = pending_jobs.first
            if filter.match?(job.klass, job.opts)
              options = Sidekiq::DeferredJobs.worker_options(job.klass, job.opts)
              dedup_key = nil
              dedup_key = [job.klass, job.args, options["queue"]] if unique_job?(options)
              unless dedup_key && @dedup_keys.include?(dedup_key)
                Sidekiq::DeferredJobs.enqueue_job(job.klass, job.args, job.opts)
              end
              @dedup_keys << dedup_key if dedup_key
            else
              unmatched_jobs << job
            end
            pending_jobs.shift
          end
        ensure
          @jobs = unmatched_jobs + pending_jobs
          @dedup_keys.clear if pending_jobs.empty?
        end
      end

      private

      # @return [Boolean] true if the options declare a uniqueness constraint
      def unique_job?(options)
        enterprise_option = options["unique_for"] if defined?(Sidekiq::Enterprise)
        unique_jobs_option = options["lock"] if defined?(SidekiqUniqueJobs)

        if enterprise_option
          true
        elsif unique_jobs_option
          unique_jobs_option.to_s != "while_executing"
        else
          false
        end
      end
    end
  end
end

require_relative "deferred_jobs_ext"
