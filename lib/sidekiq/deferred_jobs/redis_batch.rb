# frozen_string_literal: true

require "digest/sha1"

module Sidekiq
  module DeferredJobs
    # Durable backend for holding deferred jobs. Jobs are persisted to Redis for the
    # lifetime of the deferring block so they survive a process crash while deferred.
    #
    # The thread-local batch handle holds only a lazily allocated id; all job data lives
    # in Redis. The keys used are:
    #
    #   <prefix>:batch:<id>  a LIST of JSON-serialized jobs (RPUSH preserves order)
    #   <prefix>:batches     a ZSET of id => last-activity-timestamp-ms used to find orphans
    #   <prefix>:dead        a LIST of payloads that repeatedly failed to enqueue
    #
    # Flushing is done in two steps so that no job is ever lost to a process crash:
    #
    #   1. A Lua script atomically moves the batch's payloads (plus the payloads of any
    #      orphaned batches abandoned by dead processes) into a fresh in-flight list that
    #      is registered in the ZSET like any other batch.
    #   2. Each job is enqueued to Sidekiq and only then popped from the in-flight list.
    #
    # If the process dies at any point, the payloads still in the in-flight list are
    # reaped as an orphan by a later flush in any process. This makes delivery
    # at-least-once: a crash between enqueuing a job and popping it can deliver that one
    # job twice, but a job can never be silently lost.
    #
    # All timestamps are taken from the Redis server clock (TIME) so that clock skew
    # between application hosts cannot cause premature orphan reaping.
    #
    # Note: the flush script derives key names from ARGV, so it is not compatible with
    # Redis Cluster. Sidekiq itself does not support Redis Cluster.
    class RedisBatch
      # Number of attempts to atomically rewrite a batch before giving up. Rewrites only
      # need to be retried when another process reaps the batch mid-rewrite, so in
      # practice a single retry is already rare.
      MAX_CAS_ATTEMPTS = 10

      # Lua fragment defining now_ms() from the Redis server clock. Scripts that call
      # TIME must declare effect replication for Redis versions before 5.0.
      TIME_PREAMBLE = <<~LUA
        redis.replicate_commands()
        local time = redis.call('TIME')
        local now_ms = (time[1] * 1000) + math.floor(time[2] / 1000)
      LUA

      # Append a payload to a batch list and register the batch.
      #
      # KEYS[1] = batch list key
      # KEYS[2] = registry zset
      # ARGV[1] = batch id
      # ARGV[2] = ttl in ms
      # ARGV[3] = payload
      DEFER_SCRIPT = <<~LUA
        #{TIME_PREAMBLE}
        redis.call('RPUSH', KEYS[1], ARGV[3])
        redis.call('PEXPIRE', KEYS[1], ARGV[2])
        redis.call('ZADD', KEYS[2], now_ms, ARGV[1])
        redis.call('PEXPIRE', KEYS[2], ARGV[2])
        return redis.call('LLEN', KEYS[1])
      LUA

      # Atomically move the current batch plus any orphaned batches into a new in-flight
      # list registered under the flush id.
      #
      # KEYS[1] = registry zset
      # ARGV[1] = batch key prefix ("<prefix>:batch:")
      # ARGV[2] = current batch id (or "" when there is no current batch)
      # ARGV[3] = flush id for the in-flight list
      # ARGV[4] = orphan grace period in ms
      # ARGV[5] = maximum number of orphaned batches to reap
      # ARGV[6] = ttl in ms
      #
      # Returns [own_count, payloads] where the first own_count payloads came from the
      # current batch and the rest came from orphaned batches.
      FLUSH_AND_REAP_SCRIPT = <<~LUA
        #{TIME_PREAMBLE}
        local registry = KEYS[1]
        local prefix = ARGV[1]
        local current_id = ARGV[2]
        local flush_id = ARGV[3]
        local grace_ms = tonumber(ARGV[4])
        local max_orphans = tonumber(ARGV[5])
        local ttl_ms = ARGV[6]

        local flush_key = prefix .. flush_id
        local payloads = {}
        local own_count = 0

        local function move_batch(id)
          local key = prefix .. id
          local items = redis.call('LRANGE', key, 0, -1)
          redis.call('DEL', key)
          redis.call('ZREM', registry, id)
          for _, item in ipairs(items) do
            redis.call('RPUSH', flush_key, item)
            payloads[#payloads + 1] = item
          end
          return #items
        end

        if current_id ~= '' then
          own_count = move_batch(current_id)
        end

        if max_orphans > 0 then
          local cutoff = now_ms - grace_ms
          local ids = redis.call('ZRANGEBYSCORE', registry, '-inf', cutoff, 'LIMIT', 0, max_orphans)
          for _, oid in ipairs(ids) do
            if oid ~= current_id and oid ~= flush_id then
              move_batch(oid)
            end
          end
        end

        if #payloads > 0 then
          redis.call('PEXPIRE', flush_key, ttl_ms)
          redis.call('ZADD', registry, now_ms, flush_id)
          redis.call('PEXPIRE', registry, ttl_ms)
        end

        return {own_count, payloads}
      LUA

      # Atomically rewrite a batch list, but only if it has not been modified since it
      # was read (compare-and-swap). Optionally moves matched payloads into a new
      # in-flight list registered under the flush id.
      #
      # KEYS[1] = batch list key
      # KEYS[2] = registry zset
      # KEYS[3] = in-flight list key (unused when there are no matched payloads)
      # ARGV[1] = batch id
      # ARGV[2] = flush id (or "" when there are no matched payloads)
      # ARGV[3] = ttl in ms
      # ARGV[4] = number of expected payloads (E)
      # ARGV[5] = number of remaining payloads (R)
      # ARGV[6] = number of matched payloads (M)
      # ARGV[7...] = E expected payloads, then R remaining payloads, then M matched payloads
      #
      # Returns 1 on success or 0 when the list no longer matches the expected payloads.
      CAS_REWRITE_SCRIPT = <<~LUA
        #{TIME_PREAMBLE}
        local batch_key = KEYS[1]
        local registry = KEYS[2]
        local flush_key = KEYS[3]
        local batch_id = ARGV[1]
        local flush_id = ARGV[2]
        local ttl_ms = ARGV[3]
        local expected_count = tonumber(ARGV[4])
        local remaining_count = tonumber(ARGV[5])
        local matched_count = tonumber(ARGV[6])
        local base = 6

        local current = redis.call('LRANGE', batch_key, 0, -1)
        if #current ~= expected_count then
          return 0
        end
        for i = 1, expected_count do
          if current[i] ~= ARGV[base + i] then
            return 0
          end
        end

        redis.call('DEL', batch_key)
        if remaining_count > 0 then
          for i = 1, remaining_count do
            redis.call('RPUSH', batch_key, ARGV[base + expected_count + i])
          end
          redis.call('PEXPIRE', batch_key, ttl_ms)
          redis.call('ZADD', registry, now_ms, batch_id)
        else
          redis.call('ZREM', registry, batch_id)
        end

        if matched_count > 0 then
          for i = 1, matched_count do
            redis.call('RPUSH', flush_key, ARGV[base + expected_count + remaining_count + i])
          end
          redis.call('PEXPIRE', flush_key, ttl_ms)
          redis.call('ZADD', registry, now_ms, flush_id)
        end
        redis.call('PEXPIRE', registry, ttl_ms)

        return 1
      LUA

      # Acknowledge the head payload of an in-flight list after it has been handed to
      # Sidekiq, and keep the registry entry fresh while a long drain is in progress.
      #
      # KEYS[1] = in-flight list key
      # KEYS[2] = registry zset
      # ARGV[1] = flush id
      # ARGV[2] = ttl in ms
      ACK_SCRIPT = <<~LUA
        #{TIME_PREAMBLE}
        redis.call('LPOP', KEYS[1])
        if redis.call('LLEN', KEYS[1]) == 0 then
          redis.call('ZREM', KEYS[2], ARGV[1])
        else
          redis.call('ZADD', KEYS[2], now_ms, ARGV[1])
          redis.call('PEXPIRE', KEYS[1], ARGV[2])
          redis.call('PEXPIRE', KEYS[2], ARGV[2])
        end
        return redis.call('LLEN', KEYS[1])
      LUA

      # Move the head payload of an in-flight list to the tail of a target list. Used to
      # retry a payload later (target is the in-flight list itself) or to move it to the
      # dead list (target is the dead list).
      #
      # KEYS[1] = in-flight list key
      # KEYS[2] = target list key
      # KEYS[3] = registry zset
      # ARGV[1] = flush id
      # ARGV[2] = payload to push to the target
      # ARGV[3] = ttl in ms
      REQUEUE_HEAD_SCRIPT = <<~LUA
        #{TIME_PREAMBLE}
        redis.call('LPOP', KEYS[1])
        redis.call('RPUSH', KEYS[2], ARGV[2])
        redis.call('PEXPIRE', KEYS[2], ARGV[3])
        if redis.call('LLEN', KEYS[1]) == 0 then
          redis.call('ZREM', KEYS[3], ARGV[1])
        else
          redis.call('ZADD', KEYS[3], now_ms, ARGV[1])
          redis.call('PEXPIRE', KEYS[3], ARGV[3])
        end
        return redis.call('LLEN', KEYS[1])
      LUA

      # Cache of script SHA1 digests for EVALSHA.
      SCRIPT_SHAS = {}
      private_constant :SCRIPT_SHAS

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
        payload = serialize(klass, args, opts)
        @id ||= SecureRandom.uuid
        Sidekiq.redis do |conn|
          eval_script(conn, DEFER_SCRIPT, [batch_key, registry_key], [@id, ttl_ms, payload])
        end
      end

      # Remove deferred jobs matching the filter from Redis.
      #
      # @param filters [Array<Module>, Array<Hash>] Filter for jobs to clear.
      # @return [Array<Sidekiq::DeferredJobs::Job>] the jobs that were cleared.
      def clear!(filters = nil)
        return [] unless @id
        filter = Filter.new(filters)
        MAX_CAS_ATTEMPTS.times do
          pairs = read
          matched, remaining = partition_batch(pairs, filter)
          return [] if matched.empty?
          if cas_rewrite(pairs.map(&:first), remaining)
            @id = nil if remaining.empty?
            return matched.map(&:last)
          end
        end
        raise ConcurrencyError, "batch #{@id} was repeatedly modified by another process"
      end

      # Enqueue deferred jobs to Sidekiq. An unfiltered flush pops the current batch and
      # reaps orphaned batches atomically; a filtered flush only enqueues matching jobs
      # and leaves the rest deferred.
      #
      # If enqueuing one of the block's own jobs raises an error, the error is propagated
      # and the jobs that have not yet been enqueued remain in Redis, so the flush can be
      # retried without duplicating jobs that were already enqueued.
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

      # Move the current batch and any orphans into an in-flight list, then drain it.
      def full_flush
        flush_id = SecureRandom.uuid
        own_count = 0
        payloads = []
        Sidekiq.redis do |conn|
          result = eval_script(conn, FLUSH_AND_REAP_SCRIPT, [registry_key],
            ["#{key_prefix}:batch:", @id.to_s, flush_id, grace_period_ms, max_orphans, ttl_ms])
          own_count = result[0].to_i
          payloads = result[1] || []
        end
        @id = nil
        drain_in_flight(flush_id, payloads, own_count, adopt_on_error: true)
      end

      # Move only the jobs matching the filter into an in-flight list and drain it,
      # leaving non-matching jobs deferred. Orphan reaping is intentionally tied to full
      # flushes only.
      def filtered_flush(filter)
        return unless @id
        MAX_CAS_ATTEMPTS.times do
          pairs = read
          matched, remaining = partition_batch(pairs, filter)
          return if matched.empty?
          matched_raws = matched.map(&:first)
          flush_id = SecureRandom.uuid
          if cas_rewrite(pairs.map(&:first), remaining, matched_raws, flush_id)
            @id = nil if remaining.empty?
            drain_in_flight(flush_id, matched_raws, matched_raws.size, adopt_on_error: @id.nil?)
            return
          end
        end
        raise ConcurrencyError, "batch #{@id} was repeatedly modified by another process"
      end

      # Enqueue the payloads of an in-flight list in order. Each payload is popped from
      # the list only after it has been handed to Sidekiq, so a crash mid-drain leaves
      # the unfinished jobs in Redis to be reaped later instead of losing them.
      #
      # The first own_count payloads belong to the caller's own block; an error enqueuing
      # one of them is propagated so the caller can retry. The rest were reaped from
      # orphaned batches abandoned by other processes; an error enqueuing one of those is
      # contained here so it cannot break an unrelated caller's flush. Failed orphan
      # payloads are retried on later flushes until max_enqueue_attempts is reached and
      # then moved to the dead list.
      def drain_in_flight(flush_id, payloads, own_count, adopt_on_error:)
        return if payloads.empty?
        flush_key = batch_key_for(flush_id)
        duplicates = Set.new
        payloads.each_with_index do |raw, index|
          data = parse_payload(raw)
          unless data
            # An unparseable payload can never be enqueued; retrying it is pointless.
            bury(flush_key, flush_id, raw, "payload is not valid JSON")
            next
          end

          klass = constantize(data["class"])
          unless klass
            # The class may be defined in another process (e.g. during a rolling
            # deploy), so keep the payload and let a later flush retry it.
            retry_or_bury(flush_key, flush_id, data, "worker class #{data["class"].inspect} is not defined")
            next
          end

          job = Job.new(klass, data["args"] || [], data["opts"])
          suppress = false
          if DeferredJobs.unique_job?(job.klass, job.opts)
            dedup_key = DeferredJobs.dedup_key(job)
            suppress = duplicates.include?(dedup_key)
            duplicates << dedup_key
          end

          begin
            DeferredJobs.perform_job(job) unless suppress
          rescue => e
            if index < own_count
              # The payload stays at the head of the in-flight list. Adopting the list
              # as the current batch lets the caller retry it with
              # enqueue_deferred_jobs!; otherwise it is reaped after the grace period.
              @id = flush_id if adopt_on_error
              raise
            end
            retry_or_bury(flush_key, flush_id, data, "#{e.class}: #{e.message}")
            next
          end

          ack(flush_key, flush_id)
        end
      end

      # Split batch payload pairs by the filter. Payloads that cannot be deserialized
      # stay with the remaining payloads so they are never dropped here.
      #
      # @return [Array(Array<Array(String, Job)>, Array<String>)] matched pairs and remaining raw payloads.
      def partition_batch(pairs, filter)
        matched = []
        remaining = []
        pairs.each do |raw, job|
          if job && filter.match?(job.klass, job.opts)
            matched << [raw, job]
          else
            remaining << raw
          end
        end
        [matched, remaining]
      end

      # Read the current batch as an array of [raw_payload, Job] pairs. Job is nil for
      # payloads that cannot be deserialized.
      def read
        raw_payloads = Sidekiq.redis { |conn| command(conn, "LRANGE", batch_key, 0, -1) }
        raw_payloads.map { |raw| [raw, deserialize(raw)] }
      end

      # Atomically rewrite the current batch if it still contains exactly the expected
      # payloads. Matched payloads, if any, are moved to an in-flight list.
      #
      # @return [Boolean] true if the rewrite was applied.
      def cas_rewrite(expected, remaining, matched = [], flush_id = nil)
        flush_key = flush_id ? batch_key_for(flush_id) : batch_key
        argv = [@id, flush_id.to_s, ttl_ms, expected.size, remaining.size, matched.size, *expected, *remaining, *matched]
        result = Sidekiq.redis do |conn|
          eval_script(conn, CAS_REWRITE_SCRIPT, [batch_key, registry_key, flush_key], argv)
        end
        result.to_i == 1
      end

      # Pop the head of the in-flight list after its job has been handed to Sidekiq.
      def ack(flush_key, flush_id)
        Sidekiq.redis do |conn|
          eval_script(conn, ACK_SCRIPT, [flush_key, registry_key], [flush_id, ttl_ms])
        end
      end

      # Requeue a failed orphan payload for a later flush, or move it to the dead list
      # once it has failed too many times.
      def retry_or_bury(flush_key, flush_id, data, reason)
        attempts = data["attempts"].to_i + 1
        if attempts >= DeferredJobs.max_enqueue_attempts
          bury(flush_key, flush_id, JSON.generate(data), reason)
        else
          Sidekiq.logger.warn("sidekiq-deferred_jobs: could not enqueue deferred job #{data["class"]} (#{reason}); attempt #{attempts} of #{DeferredJobs.max_enqueue_attempts}")
          payload = JSON.generate(data.merge("attempts" => attempts))
          requeue_head(flush_key, flush_key, flush_id, payload)
        end
      end

      # Move the head payload of the in-flight list to the dead list.
      def bury(flush_key, flush_id, raw, reason)
        Sidekiq.logger.error("sidekiq-deferred_jobs: moving deferred job to #{dead_key} (#{reason})")
        requeue_head(flush_key, dead_key, flush_id, raw)
      end

      def requeue_head(source_key, target_key, flush_id, payload)
        Sidekiq.redis do |conn|
          eval_script(conn, REQUEUE_HEAD_SCRIPT, [source_key, target_key, registry_key], [flush_id, payload, ttl_ms])
        end
      end

      def serialize(klass, args, opts)
        name = klass.name
        if name.nil? || name.empty?
          raise ArgumentError, "cannot defer a job for an anonymous worker class; deferred jobs are serialized by class name"
        end
        JSON.generate("class" => name, "args" => args || [], "opts" => opts)
      end

      def parse_payload(raw)
        data = JSON.parse(raw)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      def deserialize(raw)
        data = parse_payload(raw)
        return nil unless data
        klass = constantize(data["class"])
        return nil unless klass
        Job.new(klass, data["args"] || [], data["opts"])
      end

      def constantize(name)
        Object.const_get(name)
      rescue NameError, TypeError
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

      # Evaluate a Lua script across both Redis client implementations, using EVALSHA
      # with an EVAL fallback so the script body is only sent when it is not yet cached.
      def eval_script(conn, script, keys, argv)
        sha = (SCRIPT_SHAS[script] ||= Digest::SHA1.hexdigest(script))
        if conn.respond_to?(:eval)
          begin
            conn.evalsha(sha, keys: keys, argv: argv)
          rescue => e
            raise unless e.message.to_s.include?("NOSCRIPT")
            conn.eval(script, keys: keys, argv: argv)
          end
        else
          begin
            conn.call("EVALSHA", sha, keys.size, *keys, *argv)
          rescue => e
            raise unless e.message.to_s.include?("NOSCRIPT")
            conn.call("EVAL", script, keys.size, *keys, *argv)
          end
        end
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

      def dead_key
        "#{key_prefix}:dead"
      end

      def batch_key
        batch_key_for(@id)
      end

      def batch_key_for(id)
        "#{key_prefix}:batch:#{id}"
      end
    end
  end
end
