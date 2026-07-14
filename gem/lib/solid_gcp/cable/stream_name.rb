# frozen_string_literal: true

module SolidGcp
  module Cable
    # Coerces streamables to a stable stream name (mirrors turbo-rails), derives
    # the Firestore doc id, and signs/verifies names with a scoped MessageVerifier.
    module StreamName
      PURPOSE = "solid_gcp/cable"

      module_function

      # Each part -> to_gid_param if GlobalID-able, else to_param/to_s; joined ":".
      def from(*streamables)
        streamables.flatten.map { |streamable| coerce(streamable) }.join(":")
      end

      def coerce(streamable)
        if streamable.respond_to?(:to_gid_param)
          streamable.to_gid_param
        elsif streamable.respond_to?(:to_param)
          streamable.to_param
        else
          streamable.to_s
        end
      end

      def doc_id(stream_name)
        Digest::SHA256.hexdigest(stream_name)
      end

      def sign(stream_name)
        verifier.generate(stream_name)
      end

      # Returns the stream name, or nil on any tamper/verify failure.
      def verify(signed_stream_name)
        verifier.verify(signed_stream_name)
      rescue StandardError
        nil
      end

      def verifier
        Rails.application.message_verifier(PURPOSE)
      end
    end
  end
end