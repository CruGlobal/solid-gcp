# frozen_string_literal: true

require "test_helper"

class OidcVerifierTest < SolidGcp::TestCase
  Config = Struct.new(:verify_oidc, :oidc_audience, :invoker_service_account, keyword_init: true)

  def config(**overrides)
    Config.new(
      verify_oidc: true,
      oidc_audience: "https://app.example.com",
      invoker_service_account: "invoker@test.iam.gserviceaccount.com",
      **overrides
    )
  end

  # Stub standing in for Google::Auth::IDTokens.
  def stub_verifier(payload)
    Class.new do
      define_method(:verify_oidc) { |_token, aud:| payload }
    end.new
  end

  test "skips when verification disabled" do
    v = SolidGcp::OidcVerifier.new(config: config(verify_oidc: false))
    assert v.verify(nil)
  end

  test "accepts a valid verified token from the invoker SA" do
    payload = { "email" => "invoker@test.iam.gserviceaccount.com", "email_verified" => true }
    v = SolidGcp::OidcVerifier.new(config: config, verifier: stub_verifier(payload))
    assert v.verify("token")
  end

  test "rejects wrong service account" do
    payload = { "email" => "someone-else@test.iam.gserviceaccount.com", "email_verified" => true }
    v = SolidGcp::OidcVerifier.new(config: config, verifier: stub_verifier(payload))
    refute v.verify("token")
  end

  test "rejects unverified email" do
    payload = { "email" => "invoker@test.iam.gserviceaccount.com", "email_verified" => false }
    v = SolidGcp::OidcVerifier.new(config: config, verifier: stub_verifier(payload))
    refute v.verify("token")
  end

  test "rejects when verifier returns false" do
    v = SolidGcp::OidcVerifier.new(config: config, verifier: stub_verifier(false))
    refute v.verify("token")
  end

  test "rejects missing token" do
    v = SolidGcp::OidcVerifier.new(config: config, verifier: stub_verifier({}))
    refute v.verify(nil)
    refute v.verify("")
  end

  test "swallows verifier exceptions as failure" do
    raising = Object.new
    def raising.verify_oidc(*) = raise("bad token")
    v = SolidGcp::OidcVerifier.new(config: config, verifier: raising)
    refute v.verify("token")
  end
end
