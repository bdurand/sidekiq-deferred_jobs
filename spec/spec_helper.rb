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

require_relative "../lib/sidekiq-deferred_jobs"

require "sidekiq/testing"

RSpec.configure do |config|
  config.warnings = true
  config.order = :random

  config.before :each do
    Sidekiq::Queues.clear_all
  end
end

module TestModule
end

class TestWorker
  include Sidekiq::Worker
  include TestModule

  sidekiq_options queue: "high", foo: "bar"

  def perform(*args)
  end
end

class UniqueWorker
  include Sidekiq::Worker

  sidekiq_options unique_for: 60, queue: "low"

  def perform(*args)
  end
end

class UniqueJobsWorker
  include Sidekiq::Worker

  sidekiq_options lock: :until_executing, queue: "high"

  def perform(*args)
  end
end
