# frozen_string_literal: true

module SolidGcp
  # In-memory test harness used by the :test backend.
  module Testing
    class << self
      def enqueued
        @enqueued ||= []
      end

      def scheduled_sweeps
        @scheduled_sweeps ||= []
      end

      def clear!
        @enqueued = []
        @scheduled_sweeps = []
      end

      def enqueued_envelopes
        enqueued.map { |t| t[:envelope] }
      end

      # Runs pending /perform + /launch envelopes through their handlers.
      # New tasks enqueued during draining (retries, promotions) are processed too.
      def drain
        results = []
        until enqueued.empty?
          task = enqueued.shift
          results << handle(task)
        end
        results
      end

      def handle(task)
        case task[:path]
        when Dispatcher::PERFORM_PATH   then Receiver.receive(task[:envelope])
        when Dispatcher::LAUNCH_PATH    then CloudRunJobLauncher.launch(task[:envelope])
        when SweepScheduler::SWEEP_PATH then Sweep.run
        end
      end
    end
  end
end
