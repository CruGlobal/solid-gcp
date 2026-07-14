# frozen_string_literal: true

module SolidGcp
  module Cable
    # Bumps a stream doc via the Firestore REST v1 `documents:commit` API. Uses a
    # single write combining an `update` (expires_at) with `updateTransforms`
    # (increment v, server-timestamp touched_at). No grpc / google-cloud-firestore.
    class Firestore
      SCOPE = "https://www.googleapis.com/auth/datastore"
      BASE = "https://firestore.googleapis.com/v1"

      def initialize(config: SolidGcp.config.cable, http: nil, authorizer: nil)
        @config = config
        @http = http || DefaultHttp.new
        @authorizer = authorizer
      end

      def touch(stream_name)
        commit(StreamName.doc_id(stream_name))
      end

      def commit(doc_id)
        response = @http.post(commit_url, commit_body(doc_id).to_json, headers)
        return if (200..299).cover?(response.code)

        raise Error, "Firestore commit failed (#{response.code}): #{response.body}"
      end

      def commit_url
        "#{BASE}/projects/#{@config.project}/databases/#{database}/documents:commit"
      end

      def commit_body(doc_id)
        expires_at = (Time.now.utc + @config.stream_ttl).iso8601
        {
          writes: [
            {
              update: {
                name: document_path(doc_id),
                fields: { "expires_at" => { "timestampValue" => expires_at } }
              },
              updateMask: { fieldPaths: ["expires_at"] },
              updateTransforms: [
                { fieldPath: "v", increment: { "integerValue" => "1" } },
                { fieldPath: "touched_at", setToServerValue: "REQUEST_TIME" }
              ]
            }
          ]
        }
      end

      private

      def document_path(doc_id)
        "projects/#{@config.project}/databases/#{database}/documents/#{@config.collection}/#{doc_id}"
      end

      def database
        @config.database
      end

      def headers
        {
          "Authorization" => "Bearer #{access_token}",
          "Content-Type" => "application/json"
        }
      end

      def access_token
        authorizer.fetch_access_token!.fetch("access_token")
      end

      def authorizer
        @authorizer ||= begin
          require "googleauth"
          Google::Auth.get_application_default(SCOPE)
        end
      end
    end
  end
end