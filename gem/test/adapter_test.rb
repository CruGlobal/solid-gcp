# frozen_string_literal: true

require "test_helper"

class AdapterTest < SolidGcp::TestCase
  def envelopes
    SolidGcp::Testing.enqueued
  end

  test "enqueue produces a versioned envelope routed to /perform" do
    PlainJob.perform_later("a", 1)

    assert_equal 1, envelopes.size
    task = envelopes.first
    assert_equal SolidGcp::Dispatcher::PERFORM_PATH, task[:path]
    assert_equal "default", task[:queue]
    assert_nil task[:schedule_time]

    env = task[:envelope]
    assert_equal 1, env["solid_gcp"]
    assert_equal "PlainJob", env["job"]["job_class"]
    assert_equal ["a", 1], env["job"]["arguments"]
    assert env["dispatched_at"]
  end

  test "enqueue_at carries a schedule time" do
    at = 5.minutes.from_now
    PlainJob.set(wait_until: at).perform_later

    task = envelopes.first
    refute_nil task[:schedule_time]
    assert_in_delta at.to_f, task[:schedule_time].to_f, 2.0
  end

  test "cloud_run_job classes route to /launch" do
    LongImportJob.perform_later(42)

    task = envelopes.first
    assert_equal SolidGcp::Dispatcher::LAUNCH_PATH, task[:path]
    assert_equal "LongImportJob", task[:envelope]["job"]["job_class"]
  end

  test "adapter enqueues after transaction commit" do
    assert ActiveJob::Base.queue_adapter.enqueue_after_transaction_commit?
  end
end
