# frozen_string_literal: true

module SolidGcp
  module Backends
    # In-process thread scheduler: sleeps until schedule_time then runs the
    # envelope through the same in-process handlers. No GCP creds needed.
    class Local
      def enqueue(queue:, path:, body:, schedule_time: nil, name: nil)
        envelope = JSON.parse(body)
        delay = schedule_time ? (schedule_time.to_time - Time.current) : 0

        Thread.new do
          sleep([delay, 0].max)
          run(path, envelope)
        rescue StandardError => e
          Rails.logger&.error("[solid_gcp:local] #{e.class}: #{e.message}") if defined?(Rails)
        end
      end

      private

      def run(path, envelope)
        wrap do
          case path
          when Dispatcher::PERFORM_PATH        then Receiver.receive(envelope)
          when Dispatcher::LAUNCH_PATH         then CloudRunJobLauncher.launch(envelope)
          when SweepScheduler::SWEEP_PATH      then Sweep.run
          end
        end
      end

      def wrap(&block)
        if defined?(Rails) && Rails.application
          Rails.application.executor.wrap(&block)
        else
          yield
        end
      end
    end
  end
end
