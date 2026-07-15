# frozen_string_literal: true

require "test_helper"

class CableCustomTokenTest < SolidGcp::TestCase
  # Returns a canned signBlob response; records the request.
  class FakeHttp
    attr_reader :url, :body

    def initialize(signature: "sig-bytes")
      @signature = signature
    end

    def post(url, body, _headers)
      @url = url
      @body = body
      SolidGcp::Cable::Response.new(
        200, { "signedBlob" => Base64.strict_encode64(@signature) }.to_json
      )
    end
  end

  FakeAuthorizer = Struct.new(:token) do
    def fetch_access_token! = { "access_token" => token }
  end

  def build(http)
    SolidGcp::Cable::CustomToken.new(
      config: SolidGcp.config.cable,
      http: http,
      authorizer: FakeAuthorizer.new("acc-tok"),
      signer_email: "runtime@proj.iam.gserviceaccount.com"
    )
  end

  def decode(segment)
    JSON.parse(Base64.urlsafe_decode64(segment))
  end

  test "signBlob is called for the configured signer with base64 payload" do
    http = FakeHttp.new
    build(http).mint(%w[doc1 doc2])

    assert_equal(
      "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/runtime@proj.iam.gserviceaccount.com:signBlob",
      http.url
    )
    payload = JSON.parse(http.body).fetch("payload")
    signing_input = Base64.strict_decode64(payload)
    assert_equal 2, signing_input.count(".") + 1 # header.payload
  end

  test "JWT has RS256 header and correct firebase claims" do
    token = build(FakeHttp.new).mint(%w[docB docA])
    header_seg, payload_seg, signature_seg = token.split(".")

    assert_equal({ "alg" => "RS256", "typ" => "JWT" }, decode(header_seg))

    payload = decode(payload_seg)
    assert_equal "runtime@proj.iam.gserviceaccount.com", payload["iss"]
    assert_equal "runtime@proj.iam.gserviceaccount.com", payload["sub"]
    assert_equal(
      "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
      payload["aud"]
    )
    assert_equal(%w[docB docA], payload.dig("claims", "sgs"))
    assert_equal Digest::SHA256.hexdigest("docA,docB"), payload["uid"]
    assert payload["exp"] > payload["iat"]

    assert_equal "sig-bytes", Base64.urlsafe_decode64(signature_seg)
  end

  # Fails the test if any HTTP call is made (emulator mode must not signBlob).
  class ExplodingHttp
    def post(*)
      raise "no HTTP call expected in emulator mode"
    end
  end

  test "auth emulator mints an unsigned token without a signBlob call" do
    SolidGcp.config.cable.auth_emulator_host = "127.0.0.1:9099"
    SolidGcp.config.cable.signer_email = nil
    token = SolidGcp::Cable::CustomToken.new(
      config: SolidGcp.config.cable,
      http: ExplodingHttp.new
    ).mint(%w[docA docB])

    header_seg, payload_seg, signature_seg = token.split(".", -1)
    assert_equal({ "alg" => "none", "typ" => "JWT" }, decode(header_seg))
    assert_equal "", signature_seg

    payload = decode(payload_seg)
    assert_equal "firebase-auth-emulator@example.com", payload["iss"]
    assert_equal "firebase-auth-emulator@example.com", payload["sub"]
    assert_equal(%w[docA docB], payload.dig("claims", "sgs"))
  end

  test "raises when signer_email cannot be resolved" do
    SolidGcp.config.cable.signer_email = nil
    token = SolidGcp::Cable::CustomToken.new(
      config: SolidGcp.config.cable,
      http: FakeHttp.new,
      authorizer: FakeAuthorizer.new("t")
    )
    def token.fetch_metadata_email = nil # no metadata server in tests

    assert_raises(SolidGcp::ConfigurationError) { token.mint(["doc1"]) }
  end
end