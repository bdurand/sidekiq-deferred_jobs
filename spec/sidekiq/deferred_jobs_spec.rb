# frozen_string_literal: true

require_relative "../spec_helper"

describe Sidekiq::DeferredJobs do
  describe "Sidekiq.defer_jobs" do
    it "should do nothing outside of a Sidekiq.defer_jobs block" do
      TestWorker.perform_async("foobar", 1)
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [["foobar", 1]]
    end

    it "should defer jobs until the end of the block" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async("foobar", 1)
        expect(TestWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [["foobar", 1]]
    end

    it "should defer jobs until the outmost defer nesting" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        Sidekiq.defer_jobs do
          TestWorker.perform_async(2)
          expect(TestWorker.jobs.size).to eq 0
        end
        TestWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1], [2], [3]]
    end

    it "should be able to disable deferring jobs in a block by passing false" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        Sidekiq.defer_jobs(false) do
          TestWorker.perform_async(2)
          expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[2]]
          TestWorker.jobs.clear
        end
        TestWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1], [3]]
    end

    it "should defer Settings" do
      Sidekiq.defer_jobs do
        TestWorker.set(foo: "bazzle").perform_async(1)
        expect(TestWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1]]
      expect(TestWorker.jobs.collect { |job| job["foo"] }).to eq ["bazzle"]
    end

    it "should not impact scheduled jobs" do
      Sidekiq.defer_jobs do
        TestWorker.perform_in(60, 1)
        expect(TestWorker.jobs.size).to eq 1
        expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1]]
      end
      expect(TestWorker.jobs.size).to eq 1
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1]]
    end
  end

  describe "Sidekiq.abort_deferred_jobs!" do
    it "should do nothing outside of a defer block" do
      TestWorker.perform_async("foobar", 1)
      Sidekiq.abort_deferred_jobs!
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [["foobar", 1]]
    end

    it "should abort all currently deferred jobs" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        TestWorker.perform_async(2)
        Sidekiq.abort_deferred_jobs!
        expect(TestWorker.jobs.size).to eq 0
        TestWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[3]]
    end

    it "should filter jobs to abort" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        Sidekiq.abort_deferred_jobs!(TestWorker)
        expect(TestWorker.jobs.size).to eq 0
        expect(UniqueWorker.jobs.size).to eq 0
        expect(UniqueJobsWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.size).to eq 0
      expect(UniqueWorker.jobs.size).to eq 1
      expect(UniqueJobsWorker.jobs.size).to eq 1
    end
  end

  describe "Sidekiq.enqueue_deferred_jobs!" do
    it "should do nothing outside of a defer block" do
      TestWorker.perform_async("foobar", 1)
      Sidekiq.enqueue_deferred_jobs!
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [["foobar", 1]]
    end

    it "should immediately enqueue all deferred jobs" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        TestWorker.perform_async(2)
        Sidekiq.enqueue_deferred_jobs!
        expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1], [2]]
        TestWorker.jobs.clear
        TestWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[3]]
    end

    it "should filter jobs to immediately enqueue" do
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        Sidekiq.enqueue_deferred_jobs!(TestWorker)
        expect(TestWorker.jobs.size).to eq 1
        expect(UniqueWorker.jobs.size).to eq 0
        expect(UniqueJobsWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.size).to eq 1
      expect(UniqueWorker.jobs.size).to eq 1
      expect(UniqueJobsWorker.jobs.size).to eq 1
    end
  end

  describe "filtering" do
    it "should filter by class" do
      Sidekiq.defer_jobs(TestWorker) do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
        expect(UniqueWorker.jobs.size).to eq 1
        expect(UniqueJobsWorker.jobs.size).to eq 1
      end
      expect(TestWorker.jobs.size).to eq 1
      expect(UniqueWorker.jobs.size).to eq 1
      expect(UniqueJobsWorker.jobs.size).to eq 1
    end

    it "should filter by module" do
      Sidekiq.defer_jobs(TestModule) do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
        expect(UniqueWorker.jobs.size).to eq 1
        expect(UniqueJobsWorker.jobs.size).to eq 1
      end
      expect(TestWorker.jobs.size).to eq 1
      expect(UniqueWorker.jobs.size).to eq 1
      expect(UniqueJobsWorker.jobs.size).to eq 1
    end

    it "should filter by sidekiq options" do
      Sidekiq.defer_jobs(queue: "high") do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
        expect(UniqueWorker.jobs.size).to eq 1
        expect(UniqueJobsWorker.jobs.size).to eq 0
      end
      expect(TestWorker.jobs.size).to eq 1
      expect(UniqueWorker.jobs.size).to eq 1
      expect(UniqueJobsWorker.jobs.size).to eq 1
    end

    it "should filter by multiple sidekiq options" do
      Sidekiq.defer_jobs(queue: "high", foo: "bar") do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
        expect(UniqueWorker.jobs.size).to eq 1
        expect(UniqueJobsWorker.jobs.size).to eq 1
      end
      expect(TestWorker.jobs.size).to eq 1
      expect(UniqueWorker.jobs.size).to eq 1
      expect(UniqueJobsWorker.jobs.size).to eq 1
    end

    it "should take multiple filters" do
      Sidekiq.defer_jobs(UniqueWorker, foo: "bar") do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        expect(TestWorker.jobs.size).to eq 0
        expect(UniqueWorker.jobs.size).to eq 0
        expect(UniqueJobsWorker.jobs.size).to eq 1
      end
      expect(TestWorker.jobs.size).to eq 1
      expect(UniqueWorker.jobs.size).to eq 1
      expect(UniqueJobsWorker.jobs.size).to eq 1
    end

    it "should nest filters" do
      Sidekiq.defer_jobs(TestWorker) do
        TestWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueJobsWorker.perform_async(3)
        Sidekiq.defer_jobs(UniqueWorker) do
          TestWorker.perform_async(4)
          UniqueWorker.perform_async(5)
          UniqueJobsWorker.perform_async(6)
        end
        TestWorker.perform_async(7)
        UniqueWorker.perform_async(8)
        UniqueJobsWorker.perform_async(9)
        expect(TestWorker.jobs.size).to eq 0
        expect(UniqueWorker.jobs.size).to eq 2
        expect(UniqueJobsWorker.jobs.size).to eq 3
      end
      expect(TestWorker.jobs.size).to eq 3
      expect(UniqueWorker.jobs.size).to eq 3
      expect(UniqueJobsWorker.jobs.size).to eq 3
    end

    it "should filter on settings" do
      Sidekiq.defer_jobs(key: "bizzle") do
        TestWorker.perform_async(1)
        TestWorker.set(key: "bizzle").perform_async(2)
        expect(TestWorker.jobs.size).to eq 1
      end
      expect(TestWorker.jobs.size).to eq 2
    end
  end

  describe "unique jobs" do
    it "should not suppress jobs that are not defined as unique" do
      stub_const("SidekiqUniqueJobs", Module.new)
      Sidekiq.defer_jobs do
        TestWorker.perform_async(1)
        TestWorker.perform_async(2)
        TestWorker.perform_async(1)
        TestWorker.perform_async(3)
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1], [2], [1], [3]]
    end

    it "should suppress sidekiq-unique-jobs duplicate jobs" do
      stub_const("SidekiqUniqueJobs", Module.new)
      Sidekiq.defer_jobs do
        UniqueJobsWorker.perform_async(1)
        UniqueJobsWorker.perform_async(2)
        UniqueJobsWorker.perform_async(1)
        UniqueJobsWorker.perform_async(3)
      end
      expect(UniqueJobsWorker.jobs.collect { |job| job["args"] }).to eq [[1], [2], [3]]
    end

    it "should suppress sidekiq enterprise duplicate jobs" do
      stub_const("Sidekiq::Enterprise", Module.new)
      Sidekiq.defer_jobs do
        UniqueWorker.perform_async(1)
        UniqueWorker.perform_async(2)
        UniqueWorker.perform_async(1)
        UniqueWorker.perform_async(3)
      end
      expect(UniqueWorker.jobs.collect { |job| job["args"] }).to eq [[1], [2], [3]]
    end

    it "should work with settings" do
      stub_const("SidekiqUniqueJobs", Module.new)
      Sidekiq.defer_jobs do
        TestWorker.set(lock: 30).perform_async(1)
        TestWorker.set(lock: 60).perform_async(1)
      end
      expect(TestWorker.jobs.collect { |job| job["args"] }).to eq [[1]]
    end
  end
end
