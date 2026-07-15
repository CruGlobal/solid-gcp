# frozen_string_literal: true

require "test_helper"
require "tempfile"

class LocalRecurringTest < SolidGcp::TestCase
  setup do
    @previous_file = SolidGcp.config.recurring_file
    @yml = Tempfile.new(["recurring", ".yml"])
  end

  teardown do
    SolidGcp::LocalRecurring.stop
    SolidGcp.config.recurring_file = @previous_file
    @yml.close!
  end

  # Writes a test-env-scoped recurring.yml and points config at it.
  def write_yml(entries)
    @yml.truncate(0)
    @yml.rewind
    @yml.write(YAML.dump("test" => entries))
    @yml.flush
    SolidGcp.config.recurring_file = @yml.path
  end

  # Poll instead of a fixed sleep so tests stay fast (≤2s ceiling).
  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep(0.05) until yield || Time.now > deadline
  end

  def enqueued_classes
    SolidGcp::Testing.enqueued.map { |task| task[:envelope]["job"]["job_class"] }
  end

  test "every-second entry fires within ~2s through the enqueue path" do
    write_yml("tick" => { "class" => "RecordingJob", "args" => ["tick"],
                          "schedule" => "* * * * * *" })

    SolidGcp::LocalRecurring.start
    wait_until { SolidGcp::Testing.enqueued.any? }

    assert_includes enqueued_classes, "RecordingJob"
  end

  test "non-cron-expressible entry is skipped with a warn; others still tick" do
    write_yml(
      "tick" => { "class" => "RecordingJob", "args" => ["tick"], "schedule" => "* * * * * *" },
      "bogus" => { "class" => "PlainJob", "schedule" => "not a real schedule" }
    )

    io = StringIO.new
    with_logger(Logger.new(io)) do
      SolidGcp::LocalRecurring.start
      wait_until { SolidGcp::Testing.enqueued.any? }
    end

    assert_includes enqueued_classes, "RecordingJob"
    refute_includes enqueued_classes, "PlainJob"
    assert_match(/recurring 'bogus': schedule not cron-expressible/, io.string)
  end

  test "start is idempotent" do
    write_yml("tick" => { "class" => "RecordingJob", "args" => ["tick"],
                          "schedule" => "* * * * * *" })

    SolidGcp::LocalRecurring.start
    SolidGcp::LocalRecurring.start

    assert_equal 1, SolidGcp::LocalRecurring.instance_variable_get(:@threads).size
  end

  test "stop halts firing" do
    write_yml("tick" => { "class" => "RecordingJob", "args" => ["tick"],
                          "schedule" => "* * * * * *" })

    SolidGcp::LocalRecurring.start
    wait_until { SolidGcp::Testing.enqueued.any? }
    SolidGcp::LocalRecurring.stop

    SolidGcp::Testing.clear!
    sleep 1.2
    assert_empty SolidGcp::Testing.enqueued
  end

  private

  def with_logger(logger)
    previous = Rails.logger
    Rails.logger = logger
    yield
  ensure
    Rails.logger = previous
  end
end
