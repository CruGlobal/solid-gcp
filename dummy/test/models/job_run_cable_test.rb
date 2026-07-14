require "test_helper"

# Proves the realtime wiring: creating a JobRun bumps the :job_runs stream.
# Cable is in :test mode (config/environments/test.rb), so the touch is captured
# by SolidGcp::Cable::TestSink instead of hitting Firestore.
class JobRunCableTest < ActiveSupport::TestCase
  # after_create_commit fires within the wrapping test transaction; draining
  # then runs the enqueued TouchJob on this connection, so keep it serial.
  self.use_transactional_tests = true

  setup do
    SolidGcp::Testing.clear!
    SolidGcp::Cable::TestSink.clear!
  end

  test "creating a JobRun enqueues a touch that records the job_runs stream" do
    JobRun.record!("PingJob", [1], note: "cable")

    # touch_later enqueued a TouchJob onto the queue component; run it.
    SolidGcp::Testing.drain

    assert_includes SolidGcp::Cable::TestSink.touches, "job_runs"
  end
end
