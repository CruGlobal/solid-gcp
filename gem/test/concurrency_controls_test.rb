# frozen_string_literal: true

require "test_helper"

class ConcurrencyControlsTest < SolidGcp::TestCase
  test "static string key" do
    assert DiscardSingletonJob.concurrency_limited?
    assert_equal "singleton", DiscardSingletonJob.new.concurrency_key
    assert_equal 1, DiscardSingletonJob.concurrency_limit
    assert_equal :discard, DiscardSingletonJob.concurrency_on_conflict
  end

  test "lambda key receives job arguments" do
    assert_equal "user/42", BlockingPerUserJob.new(42).concurrency_key
    assert_equal :block, BlockingPerUserJob.concurrency_on_conflict
  end

  test "duration falls back to config default" do
    assert_equal SolidGcp.config.default_concurrency_duration,
      BlockingPerUserJob.concurrency_duration
  end

  test "gid-able key parts are parameterized" do
    klass = Class.new(ActiveJob::Base) do
      limits_concurrency key: ->(obj) { obj }, to: 1
    end
    gid_obj = Object.new
    def gid_obj.to_gid_param = "gid://app/Widget/5"

    assert_equal "gid://app/Widget/5", klass.new(gid_obj).concurrency_key
  end

  test "non-limited job reports false" do
    refute PlainJob.concurrency_limited?
  end

  test "refuses to load alongside Solid Queue" do
    fake = Class.new do
      def self.limits_concurrency(*); end
    end

    error = assert_raises(SolidGcp::ConfigurationError) do
      SolidGcp.install_active_job_extensions(fake)
    end
    assert_match(/Solid Queue/, error.message)
  end

  test "installs mixins on a clean base" do
    base = Class.new
    SolidGcp.install_active_job_extensions(base)
    assert base.respond_to?(:limits_concurrency)
    assert base.respond_to?(:perform_via)
  end

  test "invalid on_conflict rejected" do
    assert_raises(ArgumentError) do
      Class.new(ActiveJob::Base) { limits_concurrency key: "x", on_conflict: :nope }
    end
  end
end
