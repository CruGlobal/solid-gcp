# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require "tmpdir"
require "fileutils"
DB_PATH = File.join(Dir.tmpdir, "solid_gcp_test.sqlite3")
FileUtils.rm_f(DB_PATH)
ENV["DATABASE_URL"] = "sqlite3:#{DB_PATH}?pool=25&timeout=5000"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"

require "solid_gcp"
require "active_job/queue_adapters/solid_gcp_adapter"

# Minimal host application for exercising the engine.
module Dummy
  class Application < Rails::Application
    config.eager_load = false
    config.consider_all_requests_local = true
    config.secret_key_base = "test-secret"
    config.logger = Logger.new(IO::NULL)
    config.active_job.queue_adapter = :solid_gcp
  end
end

Rails.application.initialize!

Rails.application.routes.draw do
  mount SolidGcp::Engine => "/solid_gcp"
end

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :solid_gcp_semaphores, force: true do |t|
    t.string :key, null: false
    t.integer :value, null: false, default: 1
    t.datetime :expires_at, null: false
    t.timestamps
    t.index :key, unique: true
    t.index :expires_at
  end

  create_table :solid_gcp_blocked_jobs, force: true do |t|
    t.string :concurrency_key, null: false
    t.text :serialized_envelope, null: false
    t.datetime :expires_at, null: false
    t.timestamps
    t.index :concurrency_key
    t.index :expires_at
  end

  create_table :solid_gcp_failed_jobs, force: true do |t|
    t.string :active_job_id
    t.string :job_class
    t.string :queue_name
    t.text :serialized_envelope, null: false
    t.string :error_class
    t.text :error_message
    t.text :backtrace
    t.datetime :failed_at, null: false
    t.timestamps
    t.index :active_job_id
    t.index :job_class
  end
end

# Default config for tests: in-memory test backend, OIDC off.
SolidGcp.configure do |c|
  c.mode = :test
  c.project = "test-project"
  c.location = "us-central1"
  c.push_base_url = "https://app.example.com"
  c.invoker_service_account = "invoker@test-project.iam.gserviceaccount.com"
  c.verify_oidc = false
end

require "minitest/autorun"
require "active_support/test_case"
require_relative "support/test_jobs"

module SolidGcp
  class TestCase < ActiveSupport::TestCase
    setup do
      SolidGcp.config.mode = :test
      SolidGcp.config.verify_oidc = false
      SolidGcp::Testing.clear!
      SolidGcp.instance_variable_set(:@oidc_verifier, nil)
      [SolidGcp::Semaphore, SolidGcp::BlockedJob, SolidGcp::FailedJob].each(&:delete_all)
    end
  end
end
