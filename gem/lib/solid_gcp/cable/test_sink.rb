# frozen_string_literal: true

module SolidGcp
  module Cable
    # Captures touches in :test mode instead of hitting Firestore.
    module TestSink
      module_function

      def touches
        @touches ||= []
      end

      def record(stream_name)
        touches << stream_name
      end

      def clear!
        @touches = []
      end
    end
  end
end