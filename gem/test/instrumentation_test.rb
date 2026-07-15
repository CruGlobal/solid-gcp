# frozen_string_literal: true

require "test_helper"

class InstrumentationTest < SolidGcp::TestCase
  # Collects (name, payload) for events matching the pattern during the block.
  def capture_events(pattern)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(pattern) do |name, _start, _finish, _id, payload|
      events << [name, payload]
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def envelope_for(job)
    SolidGcp::Envelope.build(job)
  end

  test "enqueue.solid_gcp fires with job_class, queue, named" do
    events = capture_events("enqueue.solid_gcp") do
      SolidGcp::Dispatcher.dispatch(PlainJob.new)
    end

    assert_equal 1, events.size
    payload = events.first.last
    assert_equal "PlainJob", payload[:job_class]
    assert_equal "default", payload[:queue]
    assert_equal false, payload[:named]
  end

  test "perform.solid_gcp reports outcome :ok on success" do
    RAN[:plain] = 0
    events = capture_events("perform.solid_gcp") do
      SolidGcp::Receiver.receive(envelope_for(PlainJob.new))
    end

    payload = events.first.last
    assert_equal "PlainJob", payload[:job_class]
    assert_equal :ok, payload[:outcome]
  end

  test "perform.solid_gcp reports outcome :failed on unhandled exception" do
    events = capture_events("perform.solid_gcp") do
      SolidGcp::Receiver.receive(envelope_for(UnhandledJob.new))
    end

    assert_equal :failed, events.first.last[:outcome]
  end

  test "perform.solid_gcp reports outcome :not_ready when infra not ready" do
    events = capture_events("perform.solid_gcp") do
      assert_raises(SolidGcp::NotReady) do
        SolidGcp::Receiver.receive(envelope_for(InfraJob.new))
      end
    end

    assert_equal :not_ready, events.first.last[:outcome]
  end

  test "perform.solid_gcp reports outcome :discarded" do
    SolidGcp::Semaphore.wait("singleton", limit: 1, duration: 60)
    events = capture_events("perform.solid_gcp") do
      SolidGcp::Receiver.receive(envelope_for(DiscardSingletonJob.new))
    end

    assert_equal :discarded, events.first.last[:outcome]
  end

  test "touch.solid_gcp fires for sync touch with doc_id" do
    SolidGcp.config.cable.mode = :test
    events = capture_events("touch.solid_gcp") do
      SolidGcp::Cable.touch(:job_runs)
    end

    payload = events.first.last
    assert_equal true, payload[:sync]
    assert_equal false, payload[:debounced]
    assert payload[:doc_id].present?
    assert_equal SolidGcp::Cable::StreamName.from(:job_runs), payload[:stream]
  end

  test "touch.solid_gcp for touch_later reports sync false" do
    SolidGcp.config.cable.mode = :test
    events = capture_events("touch.solid_gcp") do
      SolidGcp::Cable.touch_later(:job_runs)
    end

    assert_equal false, events.first.last[:sync]
  end

  test "sweep.solid_gcp fires" do
    events = capture_events("sweep.solid_gcp") { SolidGcp::Sweep.run }
    assert_equal 1, events.size
  end
end
