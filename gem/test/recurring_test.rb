# frozen_string_literal: true

require "test_helper"

class RecurringTest < SolidGcp::TestCase
  FIXTURE = File.expand_path("fixtures/recurring.yml", __dir__)
  ALIASES_FIXTURE = File.expand_path("fixtures/recurring_aliases.yml", __dir__)
  FLAT_FIXTURE = File.expand_path("fixtures/recurring_flat.yml", __dir__)
  ERB_FIXTURE = File.expand_path("fixtures/recurring_erb.yml", __dir__)

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

  # Solid Queue's own recurring.yml is conventionally written with a
  # `default: &default` anchor merged into each env, and Psych rejects aliases
  # unless asked. Loading such a file used to raise Psych::AliasesNotEnabled.
  test "loads a file that merges a YAML anchor into each env" do
    entries = SolidGcp::Recurring.load(file: ALIASES_FIXTURE, env: "test")

    assert_equal %w[cleanup heartbeat], entries.keys.sort
    assert_equal "RecordingJob", entries["cleanup"]["class"]
  end

  test "an env-scoped file with no section for this env raises rather than reading the sections as entries" do
    error = assert_raises(SolidGcp::ConfigurationError) do
      SolidGcp::Recurring.load(file: ALIASES_FIXTURE, env: "staging")
    end

    assert_match(/no recurring entries for env "staging"/, error.message)
    assert_match(/sections: default, production, test/, error.message)
  end

  test "a flat file is still the entry list, whatever the env" do
    entries = SolidGcp::Recurring.load(file: FLAT_FIXTURE, env: "staging")

    assert_equal %w[cleanup], entries.keys
    assert_equal "RecordingJob", entries["cleanup"]["class"]
  end

  # Solid Queue reads recurring.yml through ActiveSupport::ConfigurationFile, so
  # a schedule (or queue, or args) may be interpolated; we parse the same way.
  test "renders ERB in the file" do
    entries = SolidGcp::Recurring.load(file: ERB_FIXTURE, env: "test")

    assert_equal "every day at 3am", entries["cleanup"]["schedule"]

    with_env("SOLID_GCP_TEST_CLEANUP_HOUR", "5") do
      entries = SolidGcp::Recurring.load(file: ERB_FIXTURE, env: "test")

      assert_equal "every day at 5am", entries["cleanup"]["schedule"]
    end
  end

  def with_env(key, value)
    previous = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = previous
  end
end
