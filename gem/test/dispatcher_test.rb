# frozen_string_literal: true

require "test_helper"

class DispatcherTest < SolidGcp::TestCase
  # Cloud Tasks mode with a lazy client that would blow up if reached, proving
  # validation/size guards fire before any RPC.
  def with_cloud_tasks_mode
    SolidGcp.config.mode = :cloud_tasks
    yield
  ensure
    SolidGcp.config.mode = :test
  end

  test "oversized envelope raises PayloadTooLarge naming job_class and size" do
    with_cloud_tasks_mode do
      SolidGcp.config.max_task_bytes = 1_000
      job = PlainJob.new("x" * 5_000)

      error = assert_raises(SolidGcp::PayloadTooLarge) do
        SolidGcp::Dispatcher.dispatch(job)
      end

      assert_match(/PlainJob/, error.message)
      assert_match(/bytes/, error.message)
      assert_match(/max_task_bytes=1000/, error.message)
    end
  ensure
    SolidGcp.config.max_task_bytes = 900_000
  end

  test "envelope under the limit is not size-guarded (test mode ignores limit)" do
    # test backend, so no RPC; just proves a normal small job dispatches fine
    SolidGcp::Dispatcher.dispatch(PlainJob.new)
    assert_equal 1, SolidGcp::Testing.enqueued.size
  end

  test "dispatch with a missing config key raises ConfigurationError naming it" do
    with_cloud_tasks_mode do
      SolidGcp.config.project = nil

      error = assert_raises(SolidGcp::ConfigurationError) do
        SolidGcp::Dispatcher.dispatch(PlainJob.new)
      end

      assert_match(/project/, error.message)
      assert_match(/SOLID_GCP_PROJECT/, error.message)
    end
  ensure
    SolidGcp.config.project = "test-project"
  end
end
