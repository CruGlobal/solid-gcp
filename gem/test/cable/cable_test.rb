# frozen_string_literal: true

require "test_helper"
require "stringio"

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

  # --- default-on warn-once no-op --------------------------------------------

  test ":firestore mode with no resolvable project warns once and no-ops" do
    SolidGcp.config.cable.mode = :firestore
    SolidGcp.config.cable.project = nil
    SolidGcp.config.project = nil

    warnings = capture_warnings do
      assert_nil SolidGcp::Cable.touch(:job_runs)
      SolidGcp::Cable.touch_later(:job_runs)
      SolidGcp::Cable.touch(:other)
    end

    assert_equal 1, warnings.size, "expected exactly one warning per process"
    assert_match(/no project resolves/, warnings.first)
    assert_empty SolidGcp::Testing.enqueued
    assert_empty SolidGcp::Cable::TestSink.touches
  end

  # --- touch debounce (trailing, named task) ---------------------------------

  test "debounce bucket is the next trailing boundary (integer ms, deterministic)" do
    # d = 1s. now = 1_000.25s -> bucket = floor(1000.25)+1 = 1001s = 1_001_000ms.
    assert_equal 1_001_000, SolidGcp::Cable.debounce_bucket_ms(1_000.25, 1.0)
    # exactly on a boundary still rolls to the next window (trailing edge).
    assert_equal 1_001_000, SolidGcp::Cable.debounce_bucket_ms(1_000.0, 1.0)
    # sub-second debounce.
    assert_equal 1_000_500, SolidGcp::Cable.debounce_bucket_ms(1_000.1, 0.5)
  end

  test "task name format embeds doc-id prefix and bucket epoch" do
    doc_id = SolidGcp::Cable::StreamName.doc_id(SolidGcp::Cable::StreamName.from(:job_runs))

    assert_equal "sgc-touch-#{doc_id[0, 16]}-1001", SolidGcp::Cable.task_name(doc_id, 1_001_000)
    # fractional bucket -> dot swapped for hyphen (task-name-safe).
    assert_equal "sgc-touch-#{doc_id[0, 16]}-1000-5", SolidGcp::Cable.task_name(doc_id, 1_000_500)
  end

  test "touch_later in :firestore with debounce dispatches a named TouchJob task" do
    SolidGcp.config.cable.mode = :firestore # project resolves via parent test-project

    SolidGcp::Cable.touch_later(:job_runs)

    task = SolidGcp::Testing.enqueued.first
    refute_nil task
    assert_equal "SolidGcp::Cable::TouchJob", task[:envelope]["job"]["job_class"]
    assert_match(/\Asgc-touch-[0-9a-f]{16}-\d+\z/, task[:name])
    refute_nil task[:schedule_time]
  end

  test "touch_later in :firestore with debounce disabled falls back to perform_later" do
    SolidGcp.config.cable.mode = :firestore
    SolidGcp.config.cable.touch_debounce = nil

    SolidGcp::Cable.touch_later(:job_runs)

    task = SolidGcp::Testing.enqueued.first
    assert_equal "SolidGcp::Cable::TouchJob", task[:envelope]["job"]["job_class"]
    assert_nil task[:name], "no named task when debounce is disabled"
  end

  test "touch_debounce of 0 disables debounce" do
    SolidGcp.config.cable.mode = :firestore
    SolidGcp.config.cable.touch_debounce = 0

    SolidGcp::Cable.touch_later(:job_runs)

    assert_nil SolidGcp::Testing.enqueued.first[:name]
  end

  # --- local backend named-task dedup ----------------------------------------

  test "local backend dedups duplicate named tasks, allows distinct ones" do
    assert SolidGcp::Backends::Local.register_name("sgc-touch-abc-1001")
    refute SolidGcp::Backends::Local.register_name("sgc-touch-abc-1001")
    assert SolidGcp::Backends::Local.register_name("sgc-touch-abc-1002")
  end

  private

  # Captures the cable warnings emitted through Rails.logger, proving the
  # once-per-process latch without depending on the host's null log sink.
  def capture_warnings
    io = StringIO.new
    original = Rails.logger
    Rails.logger = Logger.new(io)
    yield
    io.string.lines.grep(/no project resolves/)
  ensure
    Rails.logger = original
  end
end