# frozen_string_literal: true

require "set"
require "json"
require "securerandom"
require "sidekiq"

module Sidekiq
  module DeferredJobs
    # Default number of seconds after which a batch that was never flushed is
    # considered orphaned and eligible to be reaped by another process.
    DEFAULT_GRACE_PERIOD = 300

    # Default Redis key prefix used for all keys created by this gem.
    DEFAULT_REDIS_KEY_PREFIX = "sidekiq-deferred_jobs"

    # Default maximum number of orphaned batches to reap on a single flush.
    DEFAULT_MAX_ORPHANS_PER_FLUSH = 100

    # Default TTL (in seconds) applied to batch list keys as a backstop so that
    # batches which are never reaped still expire from Redis.
    DEFAULT_ORPHAN_TTL = 86_400

    class << self
      attr_writer :grace_period, :redis_key_prefix, :max_orphans_per_flush, :orphan_ttl

      # @return [Integer] seconds before an unflushed batch may be reaped as an orphan.
      def grace_period
        @grace_period || DEFAULT_GRACE_PERIOD
      end

      # @return [String] Redis key prefix for all keys created by this gem.
      def redis_key_prefix
        @redis_key_prefix || DEFAULT_REDIS_KEY_PREFIX
      end

      # @return [Integer] maximum number of orphaned batches reaped per flush.
      def max_orphans_per_flush
        @max_orphans_per_flush || DEFAULT_MAX_ORPHANS_PER_FLUSH
      end

      # @return [Integer] backstop TTL in seconds applied to batch list keys.
      def orphan_ttl
        @orphan_ttl || DEFAULT_ORPHAN_TTL
      end

      # Defer enqueuing Sidekiq workers within the block until the end of the block.
      # Any workers that normally would have been enqueued with a `perform_async` call
      # will instead be queued up and run in an ensure clause at the end of the block.
      #
      # @param filter [Array<Module>, Array<Hash>] An array of either classes, modules, or hashes.
      #        If this is provided, only workers that match either a class or module or which have
      #        sidekiq_options that match a hash will be deferred. All other worker will be enqueued as normal.
      # @return [void]
      def defer(filter, &block)
        new_filter = Filter.new(filter)
        store = Thread.current[:sidekiq_deferred_jobs_jobs]
        unless store
          store = [nil, []]
          Thread.current[:sidekiq_deferred_jobs_jobs] = store
        end
        filters = store[1]
        filters.push(new_filter)
        begin
          yield
        ensure
          filters.pop
          if filters.empty?
            Thread.current[:sidekiq_deferred_jobs_jobs] = nil
            store[0]&.enqueue!
          end
        end
      end

      # Disable deferred workers within the block. All workers will be enqueued normally
      # within the block.
      #
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
      #
      # @param klass [Class] A Sidekiq worker class
      # @param opts [Hash, Nil] Optionsl options set at runtime for the worker.
      # @return Boolean
      def defer?(klass, opts = nil)
        store = Thread.current[:sidekiq_deferred_jobs_jobs]
        return false unless store
        store[1].any? { |filter| filter.match?(klass, opts) }
      end

      # Schedule a worker to be run at the end of the outermost defer block.
      #
      # @param klass [Class] Sidekiq worker class
      # @param args [Array] Sidekiq job arguments
      # @param opts [Hash, Nil] Optional sidekiq options specified for the job
      # @return [void]
      def defer_worker(klass, args, opts = nil)
        store = Thread.current[:sidekiq_deferred_jobs_jobs]
        if store
          batch = (store[0] ||= new_batch)
          batch.defer(klass, args, opts)
        elsif opts
          klass.set(opts).perform_async(*args)
        else
          klass.perform_async(*args)
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

      # Enqueue a single deferred job to Sidekiq.
      #
      # @param job [Sidekiq::DeferredJobs::Job]
      # @return [void]
      # @api private
      def perform_job(job)
        if job.opts
          job.klass.set(job.opts).perform_async(*job.args)
        else
          job.klass.perform_async(*job.args)
        end
      end

      # @return [Boolean] true if the worker supports a uniqueness constraint.
      # @api private
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

      # Deduplication key used to suppress duplicate unique jobs within a flush.
      #
      # @param job [Sidekiq::DeferredJobs::Job]
      # @return [Array]
      # @api private
      def dedup_key(job)
        [job.klass, job.args, worker_options(job.klass, job.opts)["queue"]]
      end

      # Merge runtime options with the worker class sidekiq_options.
      #
      # @api private
      def worker_options(klass, opts)
        if opts
          klass.sidekiq_options.merge(opts.transform_keys(&:to_s))
        else
          klass.sidekiq_options
        end
      end

      private

      # Select the storage backend for a new batch. When Sidekiq is running in a
      # testing mode, jobs are held in memory (as they always have been) so that the
      # test suite does not require a live Redis. Otherwise jobs are persisted to Redis
      # so they survive a process crash while deferred.
      def new_batch
        if defined?(Sidekiq::Testing) && Sidekiq::Testing.enabled?
          MemoryBatch.new
        else
          RedisBatch.new
        end
      end
    end

    module DeferBlock
      # Defer enqueuing Sidekiq workers within the block until the end of the block.
      # Any workers that normally would have been enqueued with a `perform_async` call
      # will instead be queued up and run in an ensure clause at the end of the block.
      #
      # @param filter [Array<Module>, Hash, false] Optional filter on which workers should be deferred.
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
      #
      # @param filter [Array<Module>, Hash, false] See #defer_job for filter specification.
      # @return [Array<Sidekiq::DeferredJobs::Job>] the jobs that were aborted
      def abort_deferred_jobs!(*filter)
        store = Thread.current[:sidekiq_deferred_jobs_jobs]
        batch = store && store[0]
        if batch
          batch.clear!(filter)
        else
          []
        end
      end

      # Immediately enqueue any already deferred Sidkiq workers in the current `defer_job` block.
      # If a filter is specified, then only matching Sidekiq jobs will be enqueued.
      #
      # @param filter [Array<Module>, Hash, false] See #defer_job for filter specification.
      # @return [void]
      def enqueue_deferred_jobs!(*filter)
        store = Thread.current[:sidekiq_deferred_jobs_jobs]
        batch = store && store[0]
        if batch
          Sidekiq::DeferredJobs.undeferred { batch.enqueue!(filter) }
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
        if !Sidekiq::DeferredJobs.scheduled_opts?(@opts) && Sidekiq::DeferredJobs.defer?(@klass, @opts)
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
        invalid = @filters.reject { |filter| filter.is_a?(Module) || filter.is_a?(Hash) }
        unless invalid.empty?
          raise ArgumentError, "Filters must be classes, modules, or hashes; got #{invalid.collect(&:inspect).join(", ")}"
        end
      end

      # @return [Boolean] true if the filter matches every job (i.e. no filter was specified).
      def match_all?
        @filters.empty?
      end

      # @return [Boolean] true if the job matches the filters.
      def match?(klass, opts = nil)
        return true if @filters.empty?
        @filters.any? do |filter|
          if filter.is_a?(Module)
            klass <= filter
          else
            worker_options = (opts ? klass.sidekiq_options.merge(opts.transform_keys(&:to_s)) : klass.sidekiq_options)
            filter.all? { |key, value| worker_options[key.to_s] == value }
          end
        end
      end
    end

    # Data structure to hold job information.
    Job = Struct.new(:klass, :args, :opts)

    # In-memory backend for holding deferred jobs. Used when Sidekiq is running in a
    # testing mode. Jobs are held in a thread-local array until they are enqueued.
    class MemoryBatch
      def initialize
        @jobs = []
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
      # If enqueuing a job raises an error, the error will be propagated to the caller
      # and any jobs that have not yet been enqueued will be retained in the deferred
      # job list so they are not silently lost and can be enqueued again.
      #
      # @param filters [Array<Module>, Array<Hash>] Filter for jobs to clear
      # @return [void]
      def enqueue!(filters = nil)
        filter = Filter.new(filters)
        unmatched_jobs = []
        pending_jobs = @jobs
        begin
          duplicates = Set.new
          until pending_jobs.empty?
            job = pending_jobs.first
            if filter.match?(job.klass, job.opts)
              suppress = false
              if DeferredJobs.unique_job?(job.klass, job.opts)
                dedup_key = DeferredJobs.dedup_key(job)
                suppress = duplicates.include?(dedup_key)
                duplicates << dedup_key
              end
              DeferredJobs.perform_job(job) unless suppress
            else
              unmatched_jobs << job
            end
            pending_jobs.shift
          end
        ensure
          @jobs = unmatched_jobs + pending_jobs
        end
      end
    end
  end
end

require_relative "deferred_jobs/redis_batch"
require_relative "deferred_jobs_ext"
