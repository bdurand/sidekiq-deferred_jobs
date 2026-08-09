# frozen_string_literal: true

require_relative "../spec_helper"
require "sidekiq/api"

# These specs exercise the durable Redis backend, so they run with Sidekiq testing mode
# disabled (which is what selects RedisBatch) against the real valkey/Redis started by
# docker-compose.
RSpec.describe Sidekiq::DeferredJobs::RedisBatch do
  let(:prefix) { Sidekiq::DeferredJobs::DEFAULT_REDIS_KEY_PREFIX }
  let(:registry) { "#{prefix}:batches" }

  around do |example|
    Sidekiq::Testing.disable! { example.run }
  end

  before do
    flush_redis!
    # Each process only scans for orphans once per grace period, so the specs that need
    # a scan start from a clean slate.
    Sidekiq::DeferredJobs::RedisBatch.reset_reap_throttle!
  end

  after do
    Sidekiq::DeferredJobs.grace_period = nil
    Sidekiq::DeferredJobs.max_orphans_per_flush = nil
    Sidekiq::DeferredJobs.max_enqueue_attempts = nil
    flush_redis!
  end

  # --- helpers -------------------------------------------------------------

  def redis_cmd(*args)
    Sidekiq.redis do |conn|
      if conn.respond_to?(:eval) # redis gem (Sidekiq 5/6)
        conn.public_send(args[0].downcase, *args.drop(1))
      else # redis-client (Sidekiq 7+)
        conn.call(*args)
      end
    end
  end

  def enqueued_args(queue)
    # Sidekiq pushes new jobs to the head of the queue list, so Sidekiq::Queue iterates
    # newest-first. Reverse to get the order the jobs were actually enqueued in.
    Sidekiq::Queue.new(queue).map(&:args).reverse
  end

  def deferred_keys
    redis_cmd("KEYS", "#{prefix}:*")
  end

  def registry_ids
    redis_cmd("ZRANGE", registry, 0, -1)
  end

  def batch_payloads(id)
    redis_cmd("LRANGE", "#{prefix}:batch:#{id}", 0, -1)
  end

  def dead_payloads
    redis_cmd("LRANGE", "#{prefix}:dead", 0, -1)
  end

  def total_deferred_payloads
    redis_cmd("KEYS", "#{prefix}:batch:*").sum { |key| redis_cmd("LLEN", key) }
  end

  def seed_batch(id, jobs, score:)
    jobs.each do |klass, args, opts|
      payload = JSON.generate("class" => klass.to_s, "args" => args, "opts" => opts)
      redis_cmd("RPUSH", "#{prefix}:batch:#{id}", payload)
    end
    redis_cmd("ZADD", registry, score, id)
  end

  def now_ms
    (Time.now.to_f * 1000).to_i
  end

  # Simulate a flush happening in another process: a fresh batch with no jobs of its own
  # still reaps any batch that is past the grace period.
  def flush_from_another_process!
    Sidekiq::DeferredJobs.undeferred { Sidekiq::DeferredJobs::RedisBatch.new.enqueue! }
  end

  # Backdate a batch's registry score so it looks idle for longer than the grace period.
  def make_idle(id)
    redis_cmd("ZADD", registry, now_ms - 10_000, id)
  end

  # --- durability ----------------------------------------------------------

  describe "durability" do
    it "persists deferred jobs to Redis for the lifetime of the block" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        TestWorker.perform_async(2)

        expect(registry_ids.size).to eq 1
        id = registry_ids.first
        expect(batch_payloads(id).size).to eq 2
        expect(enqueued_args("high")).to eq [] # nothing enqueued yet
      end

      expect(deferred_keys).to eq [] # batch + registry cleaned up
      expect(enqueued_args("high")).to eq [[1], [2]]
    end

    it "lazily allocates the batch only once a job is deferred" do
      Sidekiq.defer_jobs do
        expect(registry_ids).to eq []
        TestWorker.perform_async(1)
        expect(registry_ids.size).to eq 1
      end
      expect(enqueued_args("high")).to eq [[1]]
    end

    it "round-trips arguments and settings through Redis" do
      Sidekiq.defer_jobs do
        TestWorker.set(foo: "bazzle").perform_async("a", 1)
      end
      job = Sidekiq::Queue.new("high").first
      expect(job.args).to eq ["a", 1]
      expect(job["foo"]).to eq "bazzle"
    end

    it "keeps each job in Redis until it has been handed to Sidekiq" do
      counts_at_push_time = []
      record = lambda do |original, *args|
        counts_at_push_time << total_deferred_payloads
        original.call(*args)
      end
      # Jobs of different worker classes cannot be pushed as one bulk, so each of these
      # is handed to Sidekiq on its own.
      allow(TestWorker).to receive(:client_push).and_wrap_original(&record)
      allow(UniqueWorker).to receive(:client_push).and_wrap_original(&record)

      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
      end

      # Jobs are popped from Redis only after they are handed to Sidekiq, so a crash at
      # any point cannot lose a job. Both are still in Redis at both pushes because the
      # pops are batched and happen at the end of the flush.
      expect(counts_at_push_time).to eq [2, 2]
      expect(deferred_keys).to eq []
      expect(enqueued_args("high")).to eq [[1]]
      expect(enqueued_args("low")).to eq [[2]]
    end

    it "keeps a group in Redis until the whole group has been handed to Sidekiq" do
      skip "Sidekiq #{Sidekiq::VERSION} has no bulk push" unless TestWorker.respond_to?(:perform_bulk)

      counts_at_push_time = []
      allow(TestWorker).to receive(:perform_bulk).and_wrap_original do |original, *args|
        counts_at_push_time << total_deferred_payloads
        original.call(*args)
      end

      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        TestWorker.perform_async(2)
      end

      # Consecutive jobs of the same worker class are pushed together and popped only
      # after Sidekiq has accepted all of them.
      expect(counts_at_push_time).to eq [2]
      expect(deferred_keys).to eq []
      expect(enqueued_args("high")).to eq [[1], [2]]
    end

    it "retains only the group that could not be enqueued" do
      stub_const("Sidekiq::DeferredJobs::RedisBatch::MAX_FLUSH_GROUP", 5)
      Sidekiq::DeferredJobs.grace_period = 1
      pushes = 0
      allow(Sidekiq::DeferredJobs).to receive(:perform_jobs).and_wrap_original do |original, jobs|
        pushes += 1
        raise "Boom!" if pushes == 3
        original.call(jobs)
      end

      expect {
        Sidekiq.defer_jobs { 12.times { |i| TestWorker.perform_async(i) } }
      }.to raise_error("Boom!")

      # The two groups that were enqueued are acknowledged; the failed group is retained.
      expect(enqueued_args("high")).to eq (0..9).zip
      expect(batch_payloads(registry_ids.first).size).to eq 2

      # A later flush delivers the retained jobs, and delivers nothing a second time.
      make_idle(registry_ids.first)
      Sidekiq::DeferredJobs::RedisBatch.reset_reap_throttle!
      flush_from_another_process!

      expect(enqueued_args("high")).to eq (0..11).zip
      expect(deferred_keys).to eq []
    end

    it "raises an ArgumentError when deferring a job for an anonymous worker class" do
      anonymous_worker = Class.new do
        include SIDEKIQ_WORKER_MODULE
      end

      Sidekiq.defer_jobs do
        expect { anonymous_worker.perform_async(1) }.to raise_error(ArgumentError, /anonymous/)
      end
      expect(deferred_keys).to eq []
    end
  end

  # --- orphan reaping ------------------------------------------------------

  describe "orphan reaping" do
    it "reaps orphaned batches and enqueues their jobs when flushing" do
      seed_batch("orphan-1", [[TestWorker, [7], nil], [TestWorker, [8], nil]], score: now_ms - 10_000)
      Sidekiq::DeferredJobs.grace_period = 1

      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
      end

      expect(enqueued_args("high")).to match_array [[1], [7], [8]]
      expect(redis_cmd("LLEN", "#{prefix}:batch:orphan-1")).to eq 0
      expect(registry_ids).to eq []
    end

    it "does not reap batches newer than the grace period" do
      seed_batch("fresh-1", [[TestWorker, [99], nil]], score: now_ms)
      Sidekiq::DeferredJobs.grace_period = 300

      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
      end

      expect(enqueued_args("high")).to eq [[1]] # fresh batch untouched
      expect(redis_cmd("LLEN", "#{prefix}:batch:fresh-1")).to eq 1
      expect(registry_ids).to eq ["fresh-1"]
    end

    it "delivers an orphaned job exactly once" do
      seed_batch("orphan-1", [[TestWorker, [7], nil]], score: now_ms - 10_000)
      Sidekiq::DeferredJobs.grace_period = 1

      Sidekiq.defer_jobs { TestWorker.perform_async(1) }
      Sidekiq.defer_jobs { TestWorker.perform_async(2) }

      # The orphaned job (7) is enqueued once, by the first flush that reaped it.
      expect(enqueued_args("high")).to eq [[1], [7], [2]]
    end

    it "reaps at most max_orphans_per_flush batches" do
      seed_batch("orphan-1", [[TestWorker, [7], nil]], score: now_ms - 10_000)
      seed_batch("orphan-2", [[TestWorker, [8], nil]], score: now_ms - 10_000)
      Sidekiq::DeferredJobs.grace_period = 1
      Sidekiq::DeferredJobs.max_orphans_per_flush = 1

      Sidekiq.defer_jobs { TestWorker.perform_async(1) }

      expect(enqueued_args("high").size).to eq 2 # current + one orphan
      expect(registry_ids.size).to eq 1 # one orphan left for a later flush
    end

    it "does not let a failing reaped job break the flush that reaped it" do
      seed_batch("orphan-1", [[UniqueWorker, [7], nil]], score: now_ms - 10_000)
      Sidekiq::DeferredJobs.grace_period = 1
      allow(UniqueWorker).to receive(:client_push).and_raise("Boom!")

      expect {
        Sidekiq.defer_jobs { TestWorker.perform_async(1) }
      }.not_to raise_error

      expect(enqueued_args("high")).to eq [[1]]
      # The failed job is retained in Redis for a later attempt.
      expect(registry_ids.size).to eq 1
      retained = batch_payloads(registry_ids.first)
      expect(retained.size).to eq 1
      expect(JSON.parse(retained.first)["attempts"]).to eq 1
    end

    it "retries a reaped job whose worker class is not defined, then moves it to the dead list" do
      seed_batch("orphan-1", [["NoSuchWorkerClass", [7], nil]], score: now_ms - 10_000)
      Sidekiq::DeferredJobs.grace_period = 1
      Sidekiq::DeferredJobs.max_enqueue_attempts = 2

      Sidekiq.defer_jobs { TestWorker.perform_async(1) }

      # First attempt: the job is retained so a process that has the class can retry it.
      expect(registry_ids.size).to eq 1
      retained = batch_payloads(registry_ids.first)
      expect(retained.size).to eq 1
      expect(JSON.parse(retained.first)["attempts"]).to eq 1
      expect(dead_payloads).to eq []

      # Second attempt reaches the limit and the job is moved to the dead list.
      redis_cmd("ZADD", registry, now_ms - 10_000, registry_ids.first)
      Sidekiq::DeferredJobs::RedisBatch.reset_reap_throttle!
      Sidekiq.defer_jobs { TestWorker.perform_async(2) }

      expect(registry_ids).to eq []
      expect(dead_payloads.size).to eq 1
      expect(JSON.parse(dead_payloads.first)["class"]).to eq "NoSuchWorkerClass"
    end

    it "scans for orphans at most once per grace period in each process" do
      Sidekiq::DeferredJobs.grace_period = 300
      seed_batch("orphan-1", [[TestWorker, [7], nil]], score: now_ms - 10_000_000)

      Sidekiq.defer_jobs { TestWorker.perform_async(1) }
      expect(enqueued_args("high")).to eq [[1], [7]]

      # The next flush is well inside the grace period, so it does not scan again and
      # leaves the orphan for later.
      seed_batch("orphan-2", [[TestWorker, [8], nil]], score: now_ms - 10_000_000)
      Sidekiq.defer_jobs { TestWorker.perform_async(2) }
      expect(enqueued_args("high")).to eq [[1], [7], [2]]

      Sidekiq::DeferredJobs::RedisBatch.reset_reap_throttle!
      Sidekiq.defer_jobs { TestWorker.perform_async(3) }
      expect(enqueued_args("high")).to eq [[1], [7], [2], [3], [8]]
    end

    it "does not re-enqueue jobs that were reaped while the block was still open" do
      Sidekiq::DeferredJobs.grace_period = 1

      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        TestWorker.perform_async(2)
        make_idle(registry_ids.first)

        # Another process reaps the idle batch and enqueues its jobs early.
        flush_from_another_process!
        expect(enqueued_args("high")).to eq [[1], [2]]
        expect(registry_ids).to eq []
      end

      # The block's own flush finds an empty batch, so the jobs are not enqueued twice.
      expect(enqueued_args("high")).to eq [[1], [2]]
      expect(deferred_keys).to eq []
    end

    it "still defers jobs added after its batch was reaped" do
      Sidekiq::DeferredJobs.grace_period = 1

      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        make_idle(registry_ids.first)
        flush_from_another_process!

        TestWorker.perform_async(2)
        # The batch is registered again so the new job is durable and still deferred.
        expect(registry_ids.size).to eq 1
        expect(enqueued_args("high")).to eq [[1]]
      end

      expect(enqueued_args("high")).to eq [[1], [2]]
      expect(deferred_keys).to eq []
    end

    it "cannot abort jobs that were already reaped and enqueued by another process" do
      Sidekiq::DeferredJobs.grace_period = 1

      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        make_idle(registry_ids.first)
        flush_from_another_process!

        # The jobs are already enqueued, so there is nothing left to abort.
        expect(Sidekiq.abort_deferred_jobs!).to eq []
      end

      expect(enqueued_args("high")).to eq [[1]]
    end

    it "moves unparseable payloads to the dead list instead of dropping them" do
      redis_cmd("RPUSH", "#{prefix}:batch:orphan-1", "not json")
      redis_cmd("ZADD", registry, now_ms - 10_000, "orphan-1")
      Sidekiq::DeferredJobs.grace_period = 1

      Sidekiq.defer_jobs { TestWorker.perform_async(1) }

      expect(enqueued_args("high")).to eq [[1]]
      expect(dead_payloads).to eq ["not json"]
      expect(registry_ids).to eq []
    end
  end

  # --- unique job suppression ---------------------------------------------

  describe "unique job suppression" do
    it "suppresses duplicate unique jobs across the flush" do
      stub_const("SidekiqUniqueJobs", Module.new)
      Sidekiq.defer_jobs do
        UniqueJobsWorker.perform_async(1)
        UniqueJobsWorker.perform_async(2)
        UniqueJobsWorker.perform_async(1)
        UniqueJobsWorker.perform_async(3)
      end
      expect(enqueued_args("high")).to eq [[1], [2], [3]]
    end
  end

  # --- error retention -----------------------------------------------------

  describe "error retention" do
    it "re-persists jobs that could not be enqueued so they can be retried" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        TestWorker.perform_async(3)

        allow(UniqueWorker).to receive(:client_push).and_raise("Boom!")
        expect { Sidekiq.enqueue_deferred_jobs! }.to raise_error("Boom!")
        expect(enqueued_args("high")).to eq [[1]]
        expect(enqueued_args("low")).to eq []
        # The un-enqueued jobs remain durably in Redis.
        expect(registry_ids.size).to eq 1
        expect(batch_payloads(registry_ids.first).size).to eq 2

        allow(UniqueWorker).to receive(:client_push).and_call_original
        Sidekiq.enqueue_deferred_jobs!
        expect(enqueued_args("high")).to eq [[1], [3]]
        expect(enqueued_args("low")).to eq [[2]]
      end
      expect(deferred_keys).to eq []
    end
  end

  # --- manual control ------------------------------------------------------

  describe "abort_deferred_jobs!" do
    it "removes deferred jobs from Redis" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        TestWorker.perform_async(2)
        aborted = Sidekiq.abort_deferred_jobs!
        expect(aborted.size).to eq 2
        expect(deferred_keys).to eq []
        TestWorker.perform_async(3)
      end
      expect(enqueued_args("high")).to eq [[3]]
    end

    it "removes only matching deferred jobs from Redis" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        aborted = Sidekiq.abort_deferred_jobs!(TestWorker)
        expect(aborted.size).to eq 1
      end
      expect(enqueued_args("high")).to eq []
      expect(enqueued_args("low")).to eq [[2]]
    end

    it "does not restore jobs that another process drained between the read and the rewrite" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)

        batch = Thread.current[:sidekiq_deferred_jobs_jobs][0]
        id = registry_ids.first
        drained = false
        allow(batch).to receive(:read).and_wrap_original do |original|
          pairs = original.call
          unless drained
            drained = true
            # Simulate another process reaping and enqueuing the batch after the read.
            redis_cmd("DEL", "#{prefix}:batch:#{id}")
            redis_cmd("ZREM", registry, id)
          end
          pairs
        end

        # The stale first read fails the compare-and-swap; the retry sees the batch is
        # gone and nothing is written back to Redis to be enqueued a second time.
        expect(Sidekiq.abort_deferred_jobs!(TestWorker)).to eq []
        expect(deferred_keys).to eq []
      end

      expect(enqueued_args("high")).to eq []
      expect(enqueued_args("low")).to eq []
    end
  end

  describe "enqueue_deferred_jobs!" do
    it "immediately enqueues only matching jobs and leaves the rest deferred" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        Sidekiq.enqueue_deferred_jobs!(TestWorker)
        expect(enqueued_args("high")).to eq [[1]]
        expect(enqueued_args("low")).to eq []
        expect(registry_ids.size).to eq 1 # UniqueWorker still deferred
      end
      expect(enqueued_args("low")).to eq [[2]]
    end
  end
end
