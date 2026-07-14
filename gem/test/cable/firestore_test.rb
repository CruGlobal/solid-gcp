# frozen_string_literal: true

require "test_helper"

class CableFirestoreTest < SolidGcp::TestCase
  # Records the last POST and returns a canned response.
  class FakeHttp
    attr_reader :url, :body, :headers

    def initialize(code: 200, body: "{}")
      @code = code
      @response_body = body
    end

    def post(url, body, headers)
      @url = url
      @body = body
      @headers = headers
      SolidGcp::Cable::Response.new(@code, @response_body)
    end
  end

  FakeAuthorizer = Struct.new(:token) do
    def fetch_access_token! = { "access_token" => token }
  end

  def config
    SolidGcp.config.cable.tap { |c| c.project = "cable-proj" }
  end

  def build(http)
    SolidGcp::Cable::Firestore.new(
      config: config,
      http: http,
      authorizer: FakeAuthorizer.new("acc-tok")
    )
  end

  test "commit posts to the documents:commit endpoint with a bearer token" do
    http = FakeHttp.new
    build(http).touch("job_runs")

    assert_equal(
      "https://firestore.googleapis.com/v1/projects/cable-proj/databases/(default)/documents:commit",
      http.url
    )
    assert_equal "Bearer acc-tok", http.headers["Authorization"]
    assert_equal "application/json", http.headers["Content-Type"]
  end

  test "commit body has increment transform, server timestamp, and TTL field" do
    http = FakeHttp.new
    doc_id = SolidGcp::Cable::StreamName.doc_id(SolidGcp::Cable::StreamName.from(:job_runs))
    build(http).touch("job_runs")

    write = JSON.parse(http.body).fetch("writes").first
    transforms = write.fetch("updateTransforms")

    assert_equal ["expires_at"], write.dig("updateMask", "fieldPaths")
    assert write.dig("update", "name").end_with?("solid_gcp_streams/#{doc_id}")
    assert_equal({ "fieldPath" => "v", "increment" => { "integerValue" => "1" } }, transforms[0])
    assert_equal({ "fieldPath" => "touched_at", "setToServerValue" => "REQUEST_TIME" }, transforms[1])
    assert write.dig("update", "fields", "expires_at", "timestampValue").present?
  end

  test "raises on non-2xx commit response" do
    http = FakeHttp.new(code: 500, body: "boom")

    assert_raises(SolidGcp::Error) { build(http).touch("job_runs") }
  end
end