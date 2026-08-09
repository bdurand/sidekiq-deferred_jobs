#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare the cost of holding deferred jobs in memory against persisting them to Redis.
#
# Start a Redis with `docker compose up -d` and then run:
#
#   bundle exec ruby benchmark/deferred_jobs_benchmark.rb
#
# Three numbers are reported for each case:
#
#   trips  round trips from the client to Redis (a pipeline counts as one trip)
#   cmds   commands processed by the Redis server, including commands issued by Lua
#   objs   Ruby objects allocated
#
# The round trip count is the number that matters on a real network, because it is
# multiplied by the network latency. The command count shows the load on the Redis
# server itself.

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup"
require "benchmark"
require "logger"
require "sidekiq"

begin
  require "dotenv/load"
rescue LoadError
end

require_relative "../lib/sidekiq-deferred_jobs"

REDIS_URL = ENV["REDIS_URL"] || "redis://localhost:#{ENV["REDIS_PORT"] || 6390}/0"

Sidekiq.configure_client do |config|
  config.redis = {url: REDIS_URL}
  config.logger = Logger.new(File::NULL) if config.respond_to?(:logger=)
end

class BenchmarkWorker
  include(defined?(Sidekiq::Job) ? Sidekiq::Job : Sidekiq::Worker)

  sidekiq_options queue: "benchmark"

  def perform(*args)
  end
end

class OtherBenchmarkWorker
  include(defined?(Sidekiq::Job) ? Sidekiq::Job : Sidekiq::Worker)

  sidekiq_options queue: "benchmark"

  def perform(*args)
  end
end

# Count client to Redis round trips. A pipeline is a single round trip no matter how
# many commands it carries, which is what makes it cheap.
module RoundTripCounter
  class << self
    attr_accessor :count
  end
  self.count = 0

  def call(command, config)
    RoundTripCounter.count += 1
    super
  end

  def call_pipelined(commands, config)
    RoundTripCounter.count += 1
    super
  end
end

COUNTS_ROUND_TRIPS = defined?(RedisClient)
RedisClient.register(RoundTripCounter) if COUNTS_ROUND_TRIPS

def redis_call(*args)
  Sidekiq.redis do |conn|
    conn.respond_to?(:eval) ? conn.public_send(args[0].downcase, *args.drop(1)) : conn.call(*args)
  end
end

# Total commands processed by the server, taken from INFO commandstats so that commands
# issued from inside a Lua script are included.
def server_command_count
  info = redis_call("INFO", "commandstats").to_s
  info.scan(/calls=(\d+)/).sum { |(calls)| calls.to_i }
end

def measure(label, jobs)
  redis_call("FLUSHDB")
  redis_call("CONFIG", "RESETSTAT")

  RoundTripCounter.count = 0
  objects_before = GC.stat(:total_allocated_objects)
  elapsed = Benchmark.realtime { yield }
  objects = GC.stat(:total_allocated_objects) - objects_before
  trips = RoundTripCounter.count

  # Reading the stats costs a round trip and a command of its own, so take the counts
  # before anything else touches Redis.
  commands = server_command_count

  {
    label: label,
    jobs: jobs,
    ms: elapsed * 1000,
    trips: trips,
    commands: commands,
    objects: objects
  }
end

# Drive the in-memory backend directly. This is how the gem behaved before deferred jobs
# were persisted to Redis.
def memory_flush(count)
  batch = Sidekiq::DeferredJobs::MemoryBatch.new
  count.times { |i| batch.defer(BenchmarkWorker, [i]) }
  batch.enqueue!
end

def report(rows)
  headers = ["case", "jobs", "ms", "trips", "trips/job", "cmds", "cmds/job", "objs/job"]
  widths = headers.map(&:size)
  formatted = rows.map do |row|
    [
      row[:label],
      row[:jobs].to_s,
      format("%.1f", row[:ms]),
      COUNTS_ROUND_TRIPS ? row[:trips].to_s : "n/a",
      COUNTS_ROUND_TRIPS ? format("%.2f", row[:trips].to_f / row[:jobs]) : "n/a",
      row[:commands].to_s,
      format("%.2f", row[:commands].to_f / row[:jobs]),
      format("%.0f", row[:objects].to_f / row[:jobs])
    ]
  end
  formatted.each { |cells| cells.each_with_index { |cell, i| widths[i] = [widths[i], cell.size].max } }

  line = ->(cells) { puts cells.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ") }
  line.call(headers)
  line.call(widths.map { |width| "-" * width })
  formatted.each { |cells| line.call(cells) }
end

sizes = (ENV["SIZES"] || "1,10,100,1000").split(",").map { |size| Integer(size) }

puts "Redis: #{REDIS_URL}"
puts "Sidekiq: #{Sidekiq::VERSION}"
puts

sizes.each do |count|
  rows = []

  rows << measure("baseline perform_async", count) do
    count.times { |i| BenchmarkWorker.perform_async(i) }
  end

  rows << measure("memory batch", count) do
    memory_flush(count)
  end

  rows << measure("redis full flush", count) do
    Sidekiq.defer_jobs do
      count.times { |i| BenchmarkWorker.perform_async(i) }
    end
  end

  rows << measure("redis filtered flush", count) do
    Sidekiq.defer_jobs do
      count.times { |i| BenchmarkWorker.perform_async(i) }
      Sidekiq.enqueue_deferred_jobs!(BenchmarkWorker)
    end
  end

  # Alternating worker classes cannot be pushed as one bulk, so this is the worst case
  # for the flush.
  rows << measure("redis mixed classes", count) do
    Sidekiq.defer_jobs do
      count.times do |i|
        (i.even? ? BenchmarkWorker : OtherBenchmarkWorker).perform_async(i)
      end
    end
  end

  report(rows)
  puts
end

redis_call("FLUSHDB")
