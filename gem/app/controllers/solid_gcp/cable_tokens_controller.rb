# frozen_string_literal: true

module SolidGcp
  # Mints Firebase custom tokens for the requested signed stream names. Unlike
  # the OIDC machine endpoints, this is a same-origin, session/cookie, browser
  # endpoint, so CSRF protection stays ON.
  class CableTokensController < ActionController::Base
    protect_from_forgery with: :exception

    MAX_STREAMS = 10

    # POST /cable/token  { "signed_stream_names": [..] } -> { "token": jwt }
    def create
      signed_names = Array(params[:signed_stream_names])
      return head(:unprocessable_entity) if signed_names.size > MAX_STREAMS

      stream_names = signed_names.map { |name| Cable::StreamName.verify(name) }
      return head(:unauthorized) if stream_names.any?(&:nil?)

      doc_ids = stream_names.map { |name| Cable::StreamName.doc_id(name) }
      token = ActiveSupport::Notifications.instrument(
        "mint_token.solid_gcp", streams: doc_ids.size
      ) do
        Cable::CustomToken.new.mint(doc_ids)
      end
      render json: { token: token }
    end
  end
end