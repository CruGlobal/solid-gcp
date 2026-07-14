# frozen_string_literal: true

require "test_helper"

class ReceiverTest < SolidGcp::TestCase
  def envelope_for(job)
    SolidGcp::Envelope.build(job)
  end

  def enqueued
    SolidGcp::Testing.enqueued
  end

  test "success returns :executed" do
    RAN[:plain] = 0
    result = SolidGcp::Receiver.receive(envelope_for(PlainJob.new))
    assert_equal :executed, result
    assert_equal 1, RAN[:plain]
  end

  test "retry_on re-dispatches with a growing schedule time" do
    SolidGcp::Receiver.receive(envelope_for(RetryingJob.new))
    first = enqueued.shift
    refute_nil first[:schedule_time], "retry should schedule a future task"
    delay1 = first[:schedule_time].to_f - Time.now.to_f

    # process the retry; it should re-schedule again, with a larger wait
    SolidGcp::Receiver.receive(first[:envelope])
    second = enqueued.shift
    delay2 = second[:schedule_time].to_f - Time.now.to_f

    assert_operator delay2, :>, delay1
    assert_equal 1, first[:envelope]["job"]["executions"]
    assert_equal 2, second[:envelope]["job"]["executions"]
  end

  test "discard_on swallows the error, no failed job" do
    result = SolidGcp::Receiver.receive(envelope_for(DiscardingJob.new))
    assert_equal :executed, result
    assert_equal 0, SolidGcp::FailedJob.count
    assert_empty enqueued
  end

  class RecordingSubscriber
    attr_reader :reports
    def initialize = @reports = []
    def report(error, handled:, **) = @reports << [error, handled]
  end

  test "unhandled exception records a failed job and reports" do
    subscriber = RecordingSubscriber.new
    Rails.error.subscribe(subscriber)

    result = SolidGcp::Receiver.receive(envelope_for(UnhandledJob.new))

    assert_equal :executed, result
    assert_equal 1, SolidGcp::FailedJob.count
    row = SolidGcp::FailedJob.first
    assert_equal "UnhandledJob", row.job_class
    assert_equal "RuntimeError", row.error_class
    assert_equal "unhandled failure", row.error_message
    assert_equal false, subscriber.reports.last&.last
  end

  test "infra error raises NotReady after releasing" do
    assert_raises(SolidGcp::NotReady) do
      SolidGcp::Receiver.receive(envelope_for(InfraJob.new))
    end
  end

  test "concurrency discard path returns :discarded without executing" do
    RAN[:singleton] = 0
    SolidGcp::Semaphore.wait("singleton", limit: 1, duration: 60)

    result = SolidGcp::Receiver.receive(envelope_for(DiscardSingletonJob.new))

    assert_equal :discarded, result
    assert_equal 0, RAN[:singleton]
  end

  test "concurrency block path stores a blocked job" do
    SolidGcp::Semaphore.wait("user/7", limit: 1, duration: 60)

    result = SolidGcp::Receiver.receive(envelope_for(BlockingPerUserJob.new(7)))

    assert_equal :blocked, result
    assert_equal 1, SolidGcp::BlockedJob.where(concurrency_key: "user/7").count
  end

  test "completion promotes the oldest blocked job (FIFO)" do
    # a running job occupies the only slot
    held = envelope_for(BlockingPerUserJob.new(9))
    assert_equal :executed, SolidGcp::Receiver.receive(held) # acquires + releases immediately

    # pre-seed two blocked jobs for the same key
    SolidGcp::BlockedJob.create!(concurrency_key: "user/9",
      serialized_envelope: envelope_for(RecordingJob.new("first")).to_json,
      expires_at: 5.minutes.from_now)
    SolidGcp::BlockedJob.create!(concurrency_key: "user/9",
      serialized_envelope: envelope_for(RecordingJob.new("second")).to_json,
      expires_at: 5.minutes.from_now)

    SolidGcp::BlockedJob.release_one("user/9")
    SolidGcp::BlockedJob.release_one("user/9")

    args = enqueued.map { |t| t[:envelope]["job"]["arguments"] }
    assert_equal [["first"], ["second"]], args
    assert_equal 0, SolidGcp::BlockedJob.count
  end

  test "receiver ensure-block promotes a blocked job on normal completion" do
    SolidGcp::BlockedJob.create!(concurrency_key: "user/11",
      serialized_envelope: envelope_for(RecordingJob.new("promoted")).to_json,
      expires_at: 5.minutes.from_now)

    SolidGcp::Receiver.receive(envelope_for(BlockingPerUserJob.new(11)))

    promoted = enqueued.find { |t| t[:envelope]["job"]["arguments"] == ["promoted"] }
    refute_nil promoted
    assert_equal 0, SolidGcp::BlockedJob.count
  end
end
