# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < SolidGcp::TestCase
  def cable
    SolidGcp::Configuration.new.cable # fresh: parent project unset
  end

  test "cable project defaults to demo-solid-gcp when only the emulator is set" do
    config = cable
    config.firestore_emulator_host = "127.0.0.1:8080"

    assert_equal "demo-solid-gcp", config.project
  end

  test "cable project stays nil without an emulator host" do
    assert_nil cable.project
  end

  test "explicit project wins over the emulator default" do
    config = cable
    config.firestore_emulator_host = "127.0.0.1:8080"
    config.project = "real-proj"

    assert_equal "real-proj", config.project
  end

  test "emulator hosts default from the Admin SDK env vars" do
    ENV["FIRESTORE_EMULATOR_HOST"] = "127.0.0.1:8080"
    ENV["FIREBASE_AUTH_EMULATOR_HOST"] = "127.0.0.1:9099"

    config = cable
    assert_equal "127.0.0.1:8080", config.firestore_emulator_host
    assert_equal "127.0.0.1:9099", config.auth_emulator_host
  ensure
    ENV.delete("FIRESTORE_EMULATOR_HOST")
    ENV.delete("FIREBASE_AUTH_EMULATOR_HOST")
  end
end
