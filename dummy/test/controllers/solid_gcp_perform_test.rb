require "test_helper"

# End-to-end through the mounted engine controller: a real envelope POSTed to
# /solid_gcp/perform. OIDC verification is off in test (config default), so no
# bearer token is needed.
class SolidGcpPerformTest < ActionDispatch::IntegrationTest
  setup { SolidGcp::Testing.clear! }

  test "POST /solid_gcp/perform executes the job and returns 204" do
    body = SolidGcp::Envelope.build(PingJob.new("via-http")).to_json
    post "/solid_gcp/perform", params: body, headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :no_content
    assert_equal 1, JobRun.where(job_class: "PingJob").count
    assert_equal "via-http", JobRun.last.note
  end

  test "POST /solid_gcp/perform records unhandled failures but still returns 204" do
    body = SolidGcp::Envelope.build(DoomedJob.new("http-doom")).to_json
    post "/solid_gcp/perform", params: body, headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :no_content
    assert_equal 1, SolidGcp::FailedJob.count
  end
end
