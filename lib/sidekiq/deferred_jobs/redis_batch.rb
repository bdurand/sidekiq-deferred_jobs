# frozen_string_literal: true

module Sidekiq
  module DeferredJobs
    # Durable backend for holding deferred jobs. Jobs are persisted to Redis for the
    # lifetime of the deferring block so they survive a process crash while deferred.
    #
    # The thread-local batch handle holds only a lazily allocated id; all job data lives
    # in Redis. Two keys are used per batch:
    #
    #   <prefix>:batch:<id>  a LIST of JSON-serialized jobs (RPUSH preserves order)
    #   <prefix>:batches     a ZSET of id => creation-timestamp-ms used to find orphans
    #
    # When a batch is flushed, a Lua script atomically drains the batch list AND reaps
    # any orphaned batches (batches left behind by a process that died before flushing).
    # Because the list is deleted inside the script, each job is handed to exactly one
    # flusher, so a job can never be enqueued twice.
    class RedisBatch
      # Atomically drain the current batch and reap orphaned batches.
      #
      # KEYS[1] = registry zset
      # ARGV[1] = batch key prefix ("<prefix>:batch:")
      # ARGV[2] = current batch id (or "" when there is no current batch)
      # ARGV[3] = orphan cutoff timestamp in ms (batches at or below this score are orphans)
      # ARGV[4] = maximum number of orphaned batches to reap
      #
      # Returns a two element array: [current_job_payloads, orphan_job_payloads].
      FLUSH_AND_REAP_SCRIPT = <<~LUA
        local registry = KEYS[1]
        local prefix = ARGV[1]
        local current_id = ARGV[2]
        local cutoff = ARGV[3]
        local max_orphans = tonumber(ARGV[4])

        local current = {}
        if current_id ~= '' then
          local key = prefix .. current_id
          current = redis.call('LRANGE', key, 0, -1)
          redis.call('DEL', key)
          redis.call('ZREM', registry, current_id)
        end

        local orphans = {}
        if max_orphans > 0 then
          local ids = redis.call('ZRANGEBYSCORE', registry, '-inf', cutoff, 'LIMIT', 0, max_orphans)
          for _, oid in ipairs(ids) do
            if oid ~= current_id then
              local okey = prefix .. oid
              local items = redis.call('LRANGE', okey, 0, -1)
              redis.call('DEL', okey)
              redis.call('ZREM', registry, oid)
              for _, item in ipairs(items) do
                orphans[#orphans + 1] = item
              end
            end
          end
        end

        return {current, orphans}
      LUA

      # Atomically replace the contents of a batch list.
      #
      # KEYS[1] = batch list key
      # ARGV    = the payloads that should remain in the list
      REWRITE_SCRIPT = <<~LUA
        redis.call('DEL', KEYS[1])
        redis.call('RPUSH', KEYS[1], unpack(ARGV))
        return redis.call('LLEN', KEYS[1])
      LUA

      def initialize
        @id = nil
      end

      # Persist a deferred job to Redis, allocating a batch id on the first call.
      #
      # @param klass [Class] Sidekiq worker class.
      # @param args [Array] Sidekiq job arguments.
      # @param opts [Hash, Nil] optional runtime job options.
      # @return [void]
      def defer(klass, args, opts = nil)
        allocate! unless @id
        payload = serialize(klass, args, opts)
        Sidekiq.redis do |conn|
          command(conn, "RPUSH", batch_key, payload)
          command(conn, "PEXPIRE", batch_key, ttl_ms)
        end
      end

      # Remove deferred jobs matching the filter from Redis.
      #
      # @param filters [Array<Module>, Array<Hash>] Filter for jobs to clear.
      # @return [Array<Sidekiq::DeferredJobs::Job>] the jobs that were cleared.
      def clear!(filters = nil)
        return [] unless @id
        filter = Filter.new(filters)
        matched = []
        remaining = []
        read.each do |raw, job|
          if job && filter.match?(job.klass, job.opts)
            matched << job
          else
            remaining << raw
          end
        end
        rewrite(remaining)
        matched
      end

      # Enqueue deferred jobs to Sidekiq. An unfiltered flush pops the current batch and
      # reaps orphaned batches atomically; a filtered flush only enqueues matching jobs and
      # leaves the rest deferred.
      #
      # If enqueuing a job raises an error, the error is propagated and any jobs that have
      # not yet been enqueued are re-persisted to Redis so they are not lost and can be
      # enqueued again without duplicating jobs that were already enqueued.
      #
      # @param filters [Array<Module>, Array<Hash>] Filter for jobs to enqueue.
      # @return [void]
      def enqueue!(filters = nil)
        filter = Filter.new(filters)
        if filter.match_all?
          full_flush
        else
          filtered_flush(filter)
        end
      end

      private

      # Drain the current batch and reap orphans in one atomic Lua call, then enqueue
      # everything that was returned.
      def full_flush
        cutoff = now_ms - grace_period_ms
        current = []
        orphans = []
        Sidekiq.redis do |conn|
          result = eval_script(conn, FLUSH_AND_REAP_SCRIPT, [registry_key],
            ["#{key_prefix}:batch:", @id.to_s, cutoff.to_s, max_orphans.to_s])
          current = result[0] || []
          orphans = result[1] || []
        end
        # The Lua script already removed the current batch's list and registry entry, so
        # a later defer in the same block must allocate a fresh, registered batch.
        @id = nil
        enqueue_payloads(current + orphans)
      end

      # Enqueue only jobs matching the filter, leaving non-matching jobs deferred. Orphan
      # reaping is intentionally tied to full flushes only.
      def filtered_flush(filter)
        return unless @id
        matched = []
        remaining = []
        read.each do |raw, job|
          if job && filter.match?(job.klass, job.opts)
            matched << raw
          else
            remaining << raw
          end
        end
        rewrite(remaining)
        enqueue_payloads(matched)
      end

      # Enqueue a list of raw JSON payloads with unique-job suppression and error
      # retention. On error, the not-yet-enqueued payloads are re-persisted to Redis.
      def enqueue_payloads(payloads)
        return if payloads.empty?
        duplicates = Set.new
        remaining = payloads.dup
        begin
          until remaining.empty?
            job = deserialize(remaining.first)
            if job
              suppress = false
              if DeferredJobs.unique_job?(job.klass, job.opts)
                dedup_key = DeferredJobs.dedup_key(job)
                suppress = duplicates.include?(dedup_key)
                duplicates << dedup_key
              end
              DeferredJobs.perform_job(job) unless suppress
            end
            remaining.shift
          end
        ensure
          repersist(remaining) unless remaining.empty?
        end
      end

      # Allocate a new batch id and register it so it can be found for orphan reaping.
      def allocate!
        @id = SecureRandom.uuid
        Sidekiq.redis { |conn| command(conn, "ZADD", registry_key, now_ms, @id) }
        @id
      end

      # Read the current batch as an array of [raw_payload, Job] pairs. Job is nil for
      # payloads whose worker class cannot be resolved.
      def read
        raw_payloads = Sidekiq.redis { |conn| command(conn, "LRANGE", batch_key, 0, -1) }
        raw_payloads.map { |raw| [raw, deserialize(raw)] }
      end

      # Replace the batch list with the given payloads. When empty, the batch is removed
      # entirely and the id is released.
      def rewrite(remaining)
        Sidekiq.redis do |conn|
          if remaining.empty?
            command(conn, "DEL", batch_key)
            command(conn, "ZREM", registry_key, @id)
          else
            eval_script(conn, REWRITE_SCRIPT, [batch_key], remaining)
            command(conn, "PEXPIRE", batch_key, ttl_ms)
          end
        end
        @id = nil if remaining.empty?
      end

      # Re-persist payloads that could not be enqueued so they are retained durably.
      def repersist(payloads)
        allocate! unless @id
        Sidekiq.redis do |conn|
          command(conn, "RPUSH", batch_key, *payloads)
          command(conn, "PEXPIRE", batch_key, ttl_ms)
          command(conn, "ZADD", registry_key, now_ms, @id)
        end
      end

      def serialize(klass, args, opts)
        JSON.generate("class" => klass.name, "args" => args || [], "opts" => opts)
      end

      def deserialize(raw)
        data = JSON.parse(raw)
        klass = constantize(data["class"])
        return nil unless klass
        Job.new(klass, data["args"] || [], data["opts"])
      end

      def constantize(name)
        Object.const_get(name)
      rescue NameError
        Sidekiq.logger.warn("sidekiq-deferred_jobs: could not resolve worker class #{name.inspect}; dropping deferred job")
        nil
      end

      # Run a Redis command against either a redis-client connection (Sidekiq 7+) or a
      # redis gem connection (Sidekiq 5/6). The redis gem responds to #eval; redis-client
      # only exposes the generic #call.
      def command(conn, name, *args)
        if conn.respond_to?(:eval)
          conn.public_send(name.downcase, *args)
        else
          conn.call(name, *args)
        end
      end

      # Evaluate a Lua script across both Redis client implementations.
      def eval_script(conn, script, keys, argv)
        if conn.respond_to?(:eval)
          conn.eval(script, keys: keys, argv: argv)
        else
          conn.call("EVAL", script, keys.size, *keys, *argv)
        end
      end

      def now_ms
        (Time.now.to_f * 1000).to_i
      end

      def grace_period_ms
        (DeferredJobs.grace_period * 1000).to_i
      end

      def ttl_ms
        (DeferredJobs.orphan_ttl * 1000).to_i
      end

      def max_orphans
        DeferredJobs.max_orphans_per_flush
      end

      def key_prefix
        DeferredJobs.redis_key_prefix
      end

      def registry_key
        "#{key_prefix}:batches"
      end

      def batch_key
        "#{key_prefix}:batch:#{@id}"
      end
    end
  end
end
