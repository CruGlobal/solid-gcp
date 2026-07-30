# frozen_string_literal: true

require "test_helper"

class CableHelperTest < SolidGcp::TestCase
  # Minimal view context exposing the engine helper (like an ActionView render).
  class View
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::OutputSafetyHelper
    include SolidGcp::CableHelper
  end

  def config_json
    html = View.new.solid_gcp_cable_config_tag.to_str
    JSON.parse(html[/<script[^>]*>(.*)<\/script>/m, 1])
  end

  test "no emulator keys emitted when no emulator host is set" do
    json = config_json

    refute json.key?("firestoreEmulatorHost")
    refute json.key?("authEmulatorHost")
  end

  test "emulator hosts plus defaulted projectId/apiKey are emitted" do
    SolidGcp.config.cable.firestore_emulator_host = "127.0.0.1:8080"
    SolidGcp.config.cable.auth_emulator_host = "127.0.0.1:9099"

    json = config_json
    assert_equal "127.0.0.1:8080", json["firestoreEmulatorHost"]
    assert_equal "127.0.0.1:9099", json["authEmulatorHost"]
    assert_equal SolidGcp.config.cable.project, json["projectId"]
    assert_equal "emulator-api-key", json["apiKey"]
  end

  test "no databaseId emitted for the default database" do
    refute config_json.key?("databaseId")
  end

  test "databaseId emitted for a named database" do
    SolidGcp.config.cable.database = "solid-gcp-streams"

    assert_equal "solid-gcp-streams", config_json["databaseId"]
  end

  # The client can't tell a listener that will never resolve from one that is
  # merely slow without a deadline, so the server always states it.
  test "listen timeout emitted in ms" do
    assert_equal 10_000, config_json["listenTimeoutMs"]

    SolidGcp.config.cable.listen_timeout = 1.5.seconds

    assert_equal 1500, config_json["listenTimeoutMs"]
  ensure
    SolidGcp.config.cable.listen_timeout = 10.seconds
  end

  test "explicit firebase_web_config wins over emulator defaults" do
    SolidGcp.config.cable.firestore_emulator_host = "127.0.0.1:8080"
    SolidGcp.config.cable.firebase_web_config = {
      "projectId" => "my-proj", "apiKey" => "real-key"
    }

    json = config_json
    assert_equal "my-proj", json["projectId"]
    assert_equal "real-key", json["apiKey"]
  ensure
    SolidGcp.config.cable.firebase_web_config = {}
  end
end
