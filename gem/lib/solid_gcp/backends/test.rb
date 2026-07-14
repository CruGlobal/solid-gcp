# frozen_string_literal: true

module SolidGcp
  module Backends
    # Records enqueued tasks in memory for assertions and draining in tests.
    class Test
      def enqueue(queue:, path:, body:, schedule_time: nil, name: nil)
        Testing.enqueued << {
          queue: queue,
          path: path,
          body: body,
          schedule_time: schedule_time,
          name: name,
          envelope: JSON.parse(body)
        }
      end
    end
  end
end
