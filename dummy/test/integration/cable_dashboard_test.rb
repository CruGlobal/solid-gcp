require "test_helper"

# Cable client surface as rendered/served by the host app: the dashboard emits
# the config + stream tags the Stimulus controller reads, and the engine-mounted
# token endpoint enforces its guard rails. Happy-path token minting hits IAM
# signBlob and is unit-tested in the gem, so here we only assert the reject paths.
class CableDashboardTest < ActionDispatch::IntegrationTest
  test "dashboard renders the cable config tag and a job_runs stream element" do
    get root_path
    assert_response :success

    assert_select "script#solid-gcp-cable-config", count: 1 do |elements|
      config = JSON.parse(elements.first.text)
      assert_equal "/solid_gcp/cable/token", config["tokenPath"]
    end
    assert_select "div[data-controller='solid-gcp-cable']", count: 1
  end

  test "token endpoint rejects more than 10 streams with 422" do
    post "/solid_gcp/cable/token",
      params: { signed_stream_names: Array.new(11) { "x" } }, as: :json
    assert_response :unprocessable_entity
  end

  test "token endpoint rejects a tampered signed name with 401" do
    post "/solid_gcp/cable/token",
      params: { signed_stream_names: [ "not-a-valid-signature" ] }, as: :json
    assert_response :unauthorized
  end
end
