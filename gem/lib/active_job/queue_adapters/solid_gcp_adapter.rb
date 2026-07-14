# frozen_string_literal: true

require "solid_gcp"

module ActiveJob
  module QueueAdapters
    # Active Job adapter: `config.active_job.queue_adapter = :solid_gcp`.
    # All concurrency enforcement happens at delivery time in the Receiver, so
    # enqueue is a plain hand-off to the Dispatcher.
    class SolidGcpAdapter
      def enqueue(job)
        SolidGcp::Dispatcher.dispatch(job)
      end

      def enqueue_at(job, timestamp)
        SolidGcp::Dispatcher.dispatch(job, at: Time.at(timestamp).utc)
      end

      def enqueue_after_transaction_commit?
        true
      end
    end
  end
end
