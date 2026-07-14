# frozen_string_literal: true

module SolidGcp
  module Cable
    # Rides the queue component so `touch_later` bumps the stream doc off-request.
    class TouchJob < ActiveJob::Base
      queue_as :default

      def perform(*streamables)
        SolidGcp::Cable.touch(*streamables)
      end
    end
  end
end