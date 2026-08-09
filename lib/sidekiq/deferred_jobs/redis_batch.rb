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
    #   2. The jobs are enqueued to Sidekiq and only then popped from the in-flight list.
    #
    # If the process dies at any point, the payloads still in the in-flight list are
    # reaped as an orphan by a later flush in any process. This makes delivery
    # at-least-once: a crash between enqueuing a job and popping it can deliver that job
    # twice, but a job can never be silently lost. Jobs are enqueued and popped in groups
    # of up to MAX_FLUSH_GROUP to keep the number of round trips low, so a crash can
    # repeat a whole group rather than a single job.
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

      # Maximum number of the caller's own jobs handed to Sidekiq before they are
      # acknowledged in Redis. A larger group needs fewer round trips, but a process that
      # dies in the middle of a flush re-delivers the whole unacknowledged group instead
      # of a single job.
      MAX_FLUSH_GROUP = 100

      # Guards the timestamp of the last orphan scan made by this process.
      REAP_MUTEX = Mutex.new
      private_constant :REAP_MUTEX

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
      # The registry TTL is refreshed on every job so that the registry can never expire
      # while a batch that it tracks is still deferring jobs.
      DEFER_SCRIPT = <<~LUA
        #{TIME_PREAMBLE}
        redis.call('RPUSH', KEYS[1], ARGV[3])
        redis.call('PEXPIRE', KEYS[1], ARGV[2])
        redis.call('ZADD', KEYS[2], now_ms, ARGV[1])
        redis.call('PEXPIRE', KEYS[2], ARGV[2])
        return 1
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

        -- Move a batch list into the flush list. The first batch moved is renamed in
        -- one O(1) command; later batches are appended in chunks small enough to stay
        -- within Lua's argument stack.
        local function move_batch(id)
          local key = prefix .. id
          local items = redis.call('LRANGE', key, 0, -1)
          if #items > 0 then
            if redis.call('EXISTS', flush_key) == 0 then
              redis.call('RENAME', key, flush_key)
            else
              for i = 1, #items, 512 do
                redis.call('RPUSH', flush_key, unpack(items, i, math.min(i + 511, #items)))
              end
              redis.call('DEL', key)
            end
            for _, item in ipairs(items) do
              payloads[#payloads + 1] = item
            end
          end
          redis.call('ZREM', registry, id)
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
      # The expected contents are compared by SHA1 digest rather than by shipping the
      # expected payloads back over the network. The digest is computed over the payloads
      # joined with a NUL byte, which is unambiguous because the payloads are JSON and
      # JSON strings cannot contain a raw NUL byte.
      #
      # KEYS[1] = batch list key
      # KEYS[2] = registry zset
      # KEYS[3] = in-flight list key (unused when there are no matched payloads)
      # ARGV[1] = batch id
      # ARGV[2] = flush id (or "" when there are no matched payloads)
      # ARGV[3] = ttl in ms
      # ARGV[4] = SHA1 hex digest of the expected payloads joined with a NUL byte
      # ARGV[5] = number of remaining payloads (R)
      # ARGV[6] = number of matched payloads (M)
      # ARGV[7...] = R remaining payloads, then M matched payloads
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
        local expected_sha = ARGV[4]
        local remaining_count = tonumber(ARGV[5])
        local matched_count = tonumber(ARGV[6])
        local base = 6

        local current = redis.call('LRANGE', batch_key, 0, -1)
        if redis.sha1hex(table.concat(current, '\\0')) ~= expected_sha then
          return 0
        end

        -- Push payloads in chunks small enough to stay within Lua's argument stack.
        local function push_range(key, first, last)
          for i = first, last, 512 do
            redis.call('RPUSH', key, unpack(ARGV, i, math.min(i + 511, last)))
          end
        end

        redis.call('DEL', batch_key)
        if remaining_count > 0 then
          push_range(batch_key, base + 1, base + remaining_count)
          redis.call('PEXPIRE', batch_key, ttl_ms)
          redis.call('ZADD', registry, now_ms, batch_id)
        else
          redis.call('ZREM', registry, batch_id)
        end

        if matched_count > 0 then
          push_range(flush_key, base + remaining_count + 1, base + remaining_count + matched_count)
          redis.call('PEXPIRE', flush_key, ttl_ms)
          redis.call('ZADD', registry, now_ms, flush_id)
        end
        redis.call('PEXPIRE', registry, ttl_ms)

        return 1
      LUA

      # Acknowledge payloads at the head of an in-flight list after they have been handed
      # to Sidekiq, and keep the registry entry fresh while a long drain is in progress.
      #
      # KEYS[1] = in-flight list key
      # KEYS[2] = registry zset
      # ARGV[1] = flush id
      # ARGV[2] = ttl in ms
      # ARGV[3] = number of payloads to acknowledge
      ACK_SCRIPT = <<~LUA
        redis.replicate_commands()
        redis.call('LTRIM', KEYS[1], ARGV[3], -1)
        local remaining = redis.call('LLEN', KEYS[1])
        if remaining == 0 then
          redis.call('ZREM', KEYS[2], ARGV[1])
        else
          local time = redis.call('TIME')
          redis.call('ZADD', KEYS[2], (time[1] * 1000) + math.floor(time[2] / 1000), ARGV[1])
          redis.call('PEXPIRE', KEYS[1], ARGV[2])
          redis.call('PEXPIRE', KEYS[2], ARGV[2])
        end
        return remaining
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

      # Atomically move the entire dead list into a new in-flight list registered under
      # the flush id so its payloads can be enqueued again.
      #
      # KEYS[1] = dead list key
      # KEYS[2] = registry zset
      # ARGV[1] = flush id
      # ARGV[2] = batch key prefix ("<prefix>:batch:")
      # ARGV[3] = ttl in ms
      #
      # Returns the payloads that were moved.
      RETRY_DEAD_SCRIPT = <<~LUA
        #{TIME_PREAMBLE}
        local items = redis.call('LRANGE', KEYS[1], 0, -1)
        if #items > 0 then
          local flush_key = ARGV[2] .. ARGV[1]
          redis.call('RENAME', KEYS[1], flush_key)
          redis.call('PEXPIRE', flush_key, ARGV[3])
          redis.call('ZADD', KEYS[2], now_ms, ARGV[1])
          redis.call('PEXPIRE', KEYS[2], ARGV[3])
        end
        return items
      LUA

      # Cache of script SHA1 digests for EVALSHA.
      SCRIPT_SHAS = {}
      private_constant :SCRIPT_SHAS

      class << self
        # The orphan scan reads the registry on every flush, and a flush that finds
        # orphans must enqueue all of their jobs before it can return. Limiting the scan
        # to once per grace period keeps that cost off the majority of flushes. A batch
        # is only eligible to be reaped once it has been idle for longer than the grace
        # period, so this does not delay recovery in any meaningful way.
        #
        # @return [Boolean] true if this process should scan for orphans now.
        # @api private
        def reap_due?
          # Fully qualified because Sidekiq defines its own Process class.
          now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          REAP_MUTEX.synchronize do
            return false if @last_reap_at && now - @last_reap_at < DeferredJobs.grace_period
            @last_reap_at = now
            true
          end
        end

        # Forget when this process last scanned for orphans so that the next flush scans
        # again.
        #
        # @return [void]
        # @api private
        def reset_reap_throttle!
          REAP_MUTEX.synchronize { @last_reap_at = nil }
        end
      end

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

      # Read the payloads on the dead list.
      #
      # @return [Array<Hash, String>] parsed payload data, or the raw string for
      #   payloads that are not valid JSON.
      def dead_jobs
        raw_payloads = Sidekiq.redis { |conn| command(conn, "LRANGE", dead_key, 0, -1) }
        raw_payloads.map { |raw| parse_payload(raw) || raw }
      end

      # Enqueue the payloads on the dead list again with a fresh set of enqueue
      # attempts. Payloads that fail again go back through the normal retry flow and
      # eventually return to the dead list.
      #
      # @return [Integer] the number of payloads that were retried.
      def retry_dead!
        flush_id = SecureRandom.uuid
        payloads = Sidekiq.redis do |conn|
          eval_script(conn, RETRY_DEAD_SCRIPT, [dead_key, registry_key], [flush_id, "#{key_prefix}:batch:", ttl_ms])
        end
        payloads ||= []
        return 0 if payloads.empty?

        refreshed = payloads.map do |raw|
          data = parse_payload(raw)
          next raw unless data
          data.delete("attempts")
          JSON.generate(data)
        end
        drain(batch_key_for(flush_id), flush_id, refreshed, Set.new, contain_errors: true)
        payloads.size
      end

      private

      # Move the current batch and any orphans into an in-flight list, then drain it.
      def full_flush
        reap = self.class.reap_due?
        # Nothing was deferred and it is not this process's turn to scan for orphans, so
        # the flush has no work to do at all.
        return if @id.nil? && !reap

        flush_id = SecureRandom.uuid
        own_count = 0
        payloads = []
        begin
          Sidekiq.redis do |conn|
            result = eval_script(conn, FLUSH_AND_REAP_SCRIPT, [registry_key],
              ["#{key_prefix}:batch:", @id.to_s, flush_id, grace_period_ms, reap ? max_orphans : 0, ttl_ms])
            own_count = result[0].to_i
            payloads = result[1] || []
          end
        rescue
          # The orphan scan did not happen, so it must not count against the throttle.
          self.class.reset_reap_throttle! if reap
          raise
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

      # Enqueue the payloads of an in-flight list in order. Payloads are popped from the
      # list only after they have been handed to Sidekiq, so a crash mid-drain leaves the
      # unfinished jobs in Redis to be reaped later instead of losing them.
      #
      # The first own_count payloads belong to the caller's own block; the rest were
      # reaped from orphaned batches abandoned by other processes. The two groups have
      # different error handling, so they are drained separately.
      def drain_in_flight(flush_id, payloads, own_count, adopt_on_error:)
        return if payloads.empty?
        flush_key = batch_key_for(flush_id)
        duplicates = Set.new
        drain(flush_key, flush_id, payloads.first(own_count), duplicates,
          contain_errors: false, adopt_on_error: adopt_on_error)
        drain(flush_key, flush_id, payloads.drop(own_count), duplicates, contain_errors: true)
      end

      # Enqueue payloads in order. Consecutive jobs that share a worker class and options
      # are handed to Sidekiq in one bulk push and then acknowledged with one call, so
      # many jobs of the same kind cost a pair of round trips per group instead of a pair
      # per job.
      #
      # When contain_errors is false (the caller's own payloads), an error from Sidekiq
      # is propagated so that the caller knows the flush did not finish. The payloads
      # that were not acknowledged stay in Redis and are enqueued again by a later flush,
      # so no job is lost.
      #
      # When contain_errors is true (payloads reaped from batches that other processes
      # abandoned), an error is contained so that it cannot break the flush of an
      # unrelated caller. The failed group is retried on later flushes until
      # max_enqueue_attempts is reached and then moved to the dead list.
      def drain(flush_key, flush_id, payloads, duplicates, contain_errors:, adopt_on_error: false)
        group = []
        pending_acks = 0

        # Pop the payloads whose jobs Sidekiq has already accepted.
        flush_acks = lambda do
          if pending_acks > 0
            ack(flush_key, flush_id, pending_acks)
            pending_acks = 0
          end
        end

        # Hand the accumulated group to Sidekiq. The payloads only become acknowledgeable
        # once Sidekiq has accepted them.
        push_group = lambda do
          next if group.empty?
          begin
            DeferredJobs.perform_jobs(group.map { |_data, job| job })
          rescue => e
            # Acknowledge the jobs that were enqueued so they are not enqueued twice.
            # The failed group is at the head of the in-flight list.
            flush_acks.call
            unless contain_errors
              # Adopting the list as the current batch lets the caller retry it with
              # enqueue_deferred_jobs!; otherwise it is reaped after the grace period.
              @id = flush_id if adopt_on_error
              raise
            end
            group.each do |data, _job|
              retry_or_bury(flush_key, flush_id, data, "#{e.class}: #{e.message}")
            end
            group.clear
            next
          end
          pending_acks += group.size
          group.clear
          flush_acks.call if pending_acks >= MAX_FLUSH_GROUP
        end

        payloads.each do |raw|
          data = parse_payload(raw)
          klass = data && constantize(data["class"])
          unless klass
            # The failed payload is handled on its own, so everything ahead of it in the
            # list has to be enqueued and acknowledged first.
            push_group.call
            flush_acks.call
            if data
              # The class may be defined in another process (e.g. during a rolling
              # deploy), so keep the payload and let a later flush retry it.
              retry_or_bury(flush_key, flush_id, data, "worker class #{data["class"].inspect} is not defined")
            else
              # An unparseable payload can never be enqueued; retrying it is pointless.
              bury(flush_key, flush_id, raw, "payload is not valid JSON")
            end
            next
          end

          job = Job.new(klass, data["args"] || [], data["opts"])
          if DeferredJobs.unique_job?(job.klass, job.opts)
            dedup_key = DeferredJobs.dedup_key(job)
            if duplicates.include?(dedup_key)
              # The duplicate is not enqueued, but it can only be acknowledged once the
              # jobs ahead of it in the list have been enqueued.
              push_group.call
              pending_acks += 1
              flush_acks.call if pending_acks >= MAX_FLUSH_GROUP
              next
            end
            duplicates << dedup_key
          end

          # A bulk push can only carry jobs of one worker class with one set of options.
          leader = group.first
          if leader && !(leader[1].klass == job.klass && leader[1].opts == job.opts)
            push_group.call
          end
          group << [data, job]
          push_group.call if group.size >= MAX_FLUSH_GROUP
        end

        push_group.call
        flush_acks.call
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
      # payloads. Matched payloads, if any, are moved to an in-flight list. The expected
      # payloads are compared by digest so they do not have to be sent back to Redis.
      #
      # @return [Boolean] true if the rewrite was applied.
      def cas_rewrite(expected, remaining, matched = [], flush_id = nil)
        flush_key = flush_id ? batch_key_for(flush_id) : batch_key
        # The payloads are digested as raw bytes so the string encoding reported by the
        # Redis client cannot change the digest.
        expected_sha = Digest::SHA1.hexdigest(expected.map(&:b).join("\0"))
        argv = [@id, flush_id.to_s, ttl_ms, expected_sha, remaining.size, matched.size, *remaining, *matched]
        result = Sidekiq.redis do |conn|
          eval_script(conn, CAS_REWRITE_SCRIPT, [batch_key, registry_key, flush_key], argv)
        end
        result.to_i == 1
      end

      # Pop payloads from the head of the in-flight list after their jobs have been
      # handed to Sidekiq.
      def ack(flush_key, flush_id, count)
        Sidekiq.redis do |conn|
          eval_script(conn, ACK_SCRIPT, [flush_key, registry_key], [flush_id, ttl_ms, count])
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
