# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

begin
  require "simplecov"
  SimpleCov.start do
    add_filter ["/spec/"]
  end
rescue LoadError
end

Bundler.require(:default, :test)

begin
  require "dotenv/load"
rescue LoadError
end

require_relative "../lib/sidekiq-deferred_jobs"

require "sidekiq/testing"

# Point Sidekiq at the Redis used by the docker-compose valkey service. This is only
# actually connected to by the specs that exercise the Redis backend (with testing mode
# disabled); the default fake testing mode never touches Redis.
REDIS_URL = ENV["REDIS_URL"] || "redis://localhost:#{ENV["REDIS_PORT"] || 6390}/0"
Sidekiq.configure_client do |config|
  config.redis = {url: REDIS_URL}
end

# Flush the Redis database. Used by specs that exercise the Redis backend.
def flush_redis!
  Sidekiq.redis do |conn|
    conn.respond_to?(:flushdb) ? conn.flushdb : conn.call("FLUSHDB")
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one? || ENV["RSPEC_FORMATTER"] == "doc"
  config.order = :random
  Kernel.srand config.seed

  config.before :each do
    Sidekiq::Queues.clear_all
  end
end

module TestModule
end

class TestWorker
  include(defined?(Sidekiq::Job) ? Sidekiq::Job : Sidekiq::Worker)
  include TestModule

  sidekiq_options queue: "high", foo: "bar"

  def perform(*args)
  end
end

class UniqueWorker
  include(defined?(Sidekiq::Job) ? Sidekiq::Job : Sidekiq::Worker)

  sidekiq_options unique_for: 60, queue: "low"

  def perform(*args)
  end
end

class UniqueJobsWorker
  include(defined?(Sidekiq::Job) ? Sidekiq::Job : Sidekiq::Worker)

  sidekiq_options lock: :until_executing, queue: "high"

  def perform(*args)
  end
end
