# frozen_string_literal: true

require "test_helper"

class CableTest < SolidGcp::TestCase
  test ":off mode no-ops touch and touch_later without loading config" do
    SolidGcp.config.cable.mode = :off

    assert_nil SolidGcp::Cable.touch(:job_runs)
    SolidGcp::Cable.touch_later(:job_runs)

    assert_empty SolidGcp::Cable::TestSink.touches
    assert_empty SolidGcp::Testing.enqueued
  end

  test ":test mode records touches in the sink" do
    SolidGcp.config.cable.mode = :test

    SolidGcp::Cable.touch(:job_runs)

    assert_equal ["job_runs"], SolidGcp::Cable::TestSink.touches
  end

  test "touch_later enqueues TouchJob via the adapter" do
    SolidGcp.config.cable.mode = :test

    SolidGcp::Cable.touch_later(:job_runs)

    enqueued = SolidGcp::Testing.enqueued.first
    assert_equal "SolidGcp::Cable::TouchJob", enqueued[:envelope]["job"]["job_class"]
  end

  test "TouchJob performs a touch when run" do
    SolidGcp.config.cable.mode = :test

    SolidGcp::Cable::TouchJob.perform_now(:job_runs)

    assert_equal ["job_runs"], SolidGcp::Cable::TestSink.touches
  end
end