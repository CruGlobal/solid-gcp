# frozen_string_literal: true

require "test_helper"

class ControllerTest < ActionDispatch::IntegrationTest
  setup do
    SolidGcp.config.mode = :test
    SolidGcp.config.verify_oidc = false
    SolidGcp.config.recurring_file = File.expand_path("fixtures/recurring.yml", __dir__)
    SolidGcp::Testing.clear!
    SolidGcp.instance_variable_set(:@oidc_verifier, nil)
    [SolidGcp::Semaphore, SolidGcp::BlockedJob, SolidGcp::FailedJob].each(&:delete_all)
  end

  def post_envelope(path, job)
    post path,
      params: SolidGcp::Envelope.build(job).to_json,
      headers: { "CONTENT_TYPE" => "application/json" }
  end

  test "perform returns 204 on success" do
    post_envelope "/solid_gcp/perform", PlainJob.new
    assert_response :no_content
  end

  test "perform returns 503 on infra-not-ready" do
    post_envelope "/solid_gcp/perform", InfraJob.new
    assert_response :service_unavailable
  end

  test "perform returns 204 for unhandled job exception (AJ owns retries)" do
    post_envelope "/solid_gcp/perform", UnhandledJob.new
    assert_response :no_content
    assert_equal 1, SolidGcp::FailedJob.count
  end

  test "missing OIDC returns 401 when verification enabled" do
    SolidGcp.config.verify_oidc = true
    post_envelope "/solid_gcp/perform", PlainJob.new
    assert_response :unauthorized
  end

  test "recurring endpoint enqueues known key" do
    post "/solid_gcp/recurring/heartbeat",
      params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :no_content
    assert_equal "PlainJob", SolidGcp::Testing.enqueued.first[:envelope]["job"]["job_class"]
  end

  test "recurring endpoint returns 404 for unknown key" do
    post "/solid_gcp/recurring/bogus",
      params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
  end
end
