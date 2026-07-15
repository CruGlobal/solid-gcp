# frozen_string_literal: true

module SolidGcp
  module Cable
    # Mints a Firebase custom token (RS256 JWT). The JWT is assembled by hand and
    # signed by the runtime SA via the IAM Credentials REST `signBlob` API, so no
    # key file and no `jwt` gem are needed.
    class CustomToken
      SCOPE = "https://www.googleapis.com/auth/cloud-platform"
      IAM_BASE = "https://iamcredentials.googleapis.com/v1"
      METADATA_EMAIL_URL =
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
      AUDIENCE =
        "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit"

      def initialize(config: SolidGcp.config.cable, http: nil, authorizer: nil, signer_email: nil)
        @config = config
        @http = http || DefaultHttp.new
        @authorizer = authorizer
        @signer_email = signer_email
      end

      # doc_ids -> signed Firebase custom token authorizing get on those docs.
      def mint(doc_ids)
        signing_input = "#{encode(header)}.#{encode(payload(doc_ids))}"
        "#{signing_input}.#{sign(signing_input)}"
      end

      def header
        # The Auth emulator accepts unsigned tokens (alg "none"), matching the
        # Admin SDK's emulated signer; the real path uses RS256 via signBlob.
        return { "alg" => "none", "typ" => "JWT" } if emulator?

        { "alg" => "RS256", "typ" => "JWT" }
      end

      def payload(doc_ids)
        now = Time.now.to_i
        {
          "iss" => signer_email,
          "sub" => signer_email,
          "aud" => AUDIENCE,
          "iat" => now,
          "exp" => now + @config.token_ttl.to_i,
          "uid" => uid(doc_ids),
          "claims" => { "sgs" => doc_ids }
        }
      end

      # SHA256 of the sorted doc ids; no user identity is needed (authz is in claims).
      def uid(doc_ids)
        Digest::SHA256.hexdigest(doc_ids.sort.join(","))
      end

      def signer_email
        @resolved_signer_email ||=
          @signer_email || @config.signer_email ||
          (emulator? && "firebase-auth-emulator@example.com") ||
          fetch_metadata_email ||
          raise(ConfigurationError,
            "cable.signer_email is not set and could not be derived from the metadata server")
      end

      private

      def emulator?
        !@config.auth_emulator_host.nil?
      end

      # base64url of the raw signature bytes returned by signBlob. In emulator
      # mode the token is unsigned, so the signature segment is empty.
      def sign(signing_input)
        return "" if emulator?

        url = "#{IAM_BASE}/projects/-/serviceAccounts/#{signer_email}:signBlob"
        body = { "payload" => Base64.strict_encode64(signing_input) }.to_json
        response = Cable.request(@http, url, body, iam_headers, action: "signBlob")

        signed_blob = JSON.parse(response.body).fetch("signedBlob")
        base64url(Base64.decode64(signed_blob))
      end

      def encode(data)
        base64url(data.to_json)
      end

      def base64url(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end

      def iam_headers
        {
          "Authorization" => "Bearer #{access_token}",
          "Content-Type" => "application/json"
        }
      end

      def access_token
        authorizer.fetch_access_token!.fetch("access_token")
      end

      def authorizer
        @authorizer ||= Cable.default_authorizer(SCOPE)
      end

      def fetch_metadata_email
        uri = URI(METADATA_EMAIL_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 1
        http.read_timeout = 1
        request = Net::HTTP::Get.new(uri)
        request["Metadata-Flavor"] = "Google"
        response = http.request(request)
        response.body.strip if response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        nil
      end
    end
  end
end