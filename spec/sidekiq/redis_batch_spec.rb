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
  end

  after do
    Sidekiq::DeferredJobs.grace_period = nil
    Sidekiq::DeferredJobs.max_orphans_per_flush = nil
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
