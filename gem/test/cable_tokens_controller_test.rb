# frozen_string_literal: true

require "test_helper"

class CableTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    SolidGcp.config.cable.mode = :test
    @forgery_default = ActionController::Base.allow_forgery_protection
    # Exercise the controller logic without a CSRF token in most tests.
    ActionController::Base.allow_forgery_protection = false

    @fake_token = Object.new
    def @fake_token.mint(doc_ids) = "header.#{doc_ids.join('-')}.sig"
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_default
  end

  def signed(*streamables)
    SolidGcp::Cable::StreamName.sign(SolidGcp::Cable::StreamName.from(*streamables))
  end

  # Swap CustomToken.new for a fake so the controller never mints via GCP.
  def with_stubbed_token
    fake = @fake_token
    SolidGcp::Cable::CustomToken.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    SolidGcp::Cable::CustomToken.singleton_class.send(:remove_method, :new)
  end

  def post_token(names)
    with_stubbed_token do
      post "/solid_gcp/cable/token",
        params: { signed_stream_names: names },
        as: :json
    end
  end

  test "happy path mints a token for valid signed names" do
    post_token([signed(:job_runs)])

    assert_response :ok
    assert JSON.parse(response.body)["token"].present?
  end

  test "bad signature returns 401" do
    post_token(["not-a-valid-signature"])

    assert_response :unauthorized
  end

  test "more than 10 streams returns 422" do
    post_token(Array.new(11) { |i| signed("stream-#{i}") })

    assert_response :unprocessable_content
  end

  test "CSRF protection is enforced" do
    ActionController::Base.allow_forgery_protection = true

    # A request that would otherwise mint (1 valid stream) is rejected without
    # a valid authenticity token -> proves forgery protection is active.
    post_token([signed(:job_runs)])

    assert_response :unprocessable_content
  end
end