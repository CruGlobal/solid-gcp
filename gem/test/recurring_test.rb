# frozen_string_literal: true

require "test_helper"

class RecurringTest < SolidGcp::TestCase
  FIXTURE = File.expand_path("fixtures/recurring.yml", __dir__)

  setup do
    @previous = SolidGcp.config.recurring_file
    SolidGcp.config.recurring_file = FIXTURE
  end

  teardown do
    SolidGcp.config.recurring_file = @previous
  end

  test "loads env-scoped entries" do
    entries = SolidGcp::Recurring.load
    assert_equal %w[cleanup heartbeat run_command too_frequent].sort, entries.keys.sort
    assert_equal "RecordingJob", entries["cleanup"]["class"]
  end

  test "converts natural-language and cron schedules via fugit" do
    assert_equal "0 3 * * *", SolidGcp::Recurring.cron_for(SolidGcp::Recurring.entry("cleanup"))
    assert_equal "0 * * * *", SolidGcp::Recurring.cron_for(SolidGcp::Recurring.entry("run_command"))

    # fugit expands "*/5" to an explicit minute list; still a valid 5-field cron
    heartbeat = SolidGcp::Recurring.cron_for(SolidGcp::Recurring.entry("heartbeat"))
    assert_equal 5, heartbeat.split(/\s+/).size
    assert_equal "0,5,10,15,20,25,30,35,40,45,50,55", heartbeat.split(/\s+/).first
  end

  test "rejects non-cron schedules" do
    assert_raises(SolidGcp::ConfigurationError) do
      SolidGcp::Recurring.cron_for(SolidGcp::Recurring.entry("too_frequent"))
    end
  end

  test "enqueue with class + args + queue" do
    assert SolidGcp::Recurring.enqueue("cleanup")
    task = SolidGcp::Testing.enqueued.first
    assert_equal "maintenance", task[:queue]
    assert_equal "RecordingJob", task[:envelope]["job"]["job_class"]
    assert_equal ["cleanup"], task[:envelope]["job"]["arguments"]
  end

  test "enqueue command entry uses RecurringCommandJob" do
    assert SolidGcp::Recurring.enqueue("run_command")
    task = SolidGcp::Testing.enqueued.first
    assert_equal "SolidGcp::RecurringCommandJob", task[:envelope]["job"]["job_class"]
    assert_equal ["RAN[:command] += 1"], task[:envelope]["job"]["arguments"]
  end

  test "unknown key returns false" do
    refute SolidGcp::Recurring.enqueue("nope")
  end
end
