# frozen_string_literal: true

module SolidGcp
  # Verifies the OIDC bearer token minted by Cloud Tasks / Cloud Scheduler.
  # The underlying verifier is injectable so tests never hit Google.
  class OidcVerifier
    def initialize(config: SolidGcp.config, verifier: nil)
      @config = config
      @verifier = verifier
    end

    # Returns true when the token is valid, from the expected invoker SA, and
    # email-verified. Returns true (skip) when verification is disabled.
    def verify(token)
      return true unless @config.verify_oidc
      return false if token.nil? || token.empty?

      payload = verifier.verify_oidc(token, aud: @config.oidc_audience)
      return false unless payload

      payload["email"] == @config.invoker_service_account &&
        !!payload["email_verified"]
    rescue StandardError
      false
    end

    def verifier
      @verifier ||= begin
        require "googleauth"
        require "googleauth/id_tokens"
        Google::Auth::IDTokens
      end
    end
  end
end
