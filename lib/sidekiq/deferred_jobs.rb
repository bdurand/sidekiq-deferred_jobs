# frozen_string_literal: true

require "sidekiq"

module Sidekiq
  module DeferredJobs
    class << self
      def defer(filter)
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

      def undeferred
        save_val = Thread.current[:sidekiq_deferred_jobs_jobs]
        begin
          Thread.current[:sidekiq_deferred_jobs_jobs] = nil
          yield
        ensure
          Thread.current[:sidekiq_deferred_jobs_jobs] = save_val
        end
      end

      def defer?(klass, opts = nil)
        _jobs, filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        return false if filters.nil?
        filters.any? { |filter| filter.match?(klass, opts) }
      end

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
      def defer_jobs(*filter, &block)
        if filter.size == 1 && filter.first == false
          Sidekiq::DeferredJobs.undeferred(&block)
        else
          Sidekiq::DeferredJobs.defer(filter, &block)
        end
      end

      def abort_deferred_jobs!(*filter)
        jobs, _filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        if jobs
          jobs.clear!(filter)
        end
        nil
      end

      def enqueue_deferred_jobs!(*filter)
        jobs, _filters = Thread.current[:sidekiq_deferred_jobs_jobs]
        if jobs
          Sidekiq::DeferredJobs.undeferred { jobs.enqueue!(filter) }
        end
        nil
      end
    end

    module DeferredWorker
      def perform_async(*args)
        if Sidekiq::DeferredJobs.defer?(self)
          Sidekiq::DeferredJobs.defer_worker(self, args)
        else
          super
        end
      end
    end

    module DeferredSetter
      def perform_async(*args)
        if Sidekiq::DeferredJobs.defer?(@klass, @opts)
          Sidekiq::DeferredJobs.defer_worker(@klass, args, @opts)
        else
          super
        end
      end
    end

    class Filter
      def initialize(filters)
        @filters = Array(filters).flatten
      end

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

    class Jobs
      def initialize
        @jobs = []
      end

      def defer(klass, args, opts = nil)
        @jobs << [klass, args, opts]
      end

      def clear!(filters = nil)
        filter = Filter.new(filters)
        @jobs = @jobs.reject { |klass, _args, opts| filter.match?(klass, opts) }
      end

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

      def unique_job?(klass, opts)
        if defined?(Sidekiq::Enterprise) && worker_options(klass, opts)["unique_for"]
          true
        elsif defined?(SidekiqUniqueJobs) && worker_options(klass, opts)["lock"]
          true
        else
          false
        end
      end

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
