# frozen_string_literal: true

require "set"

module SolidGcp
  module Backends
    # In-process thread scheduler: sleeps until schedule_time then runs the
    # envelope through the same in-process handlers. No GCP creds needed.
    class Local
      # Named tasks are deduped in-process (emulates Cloud Tasks ALREADY_EXISTS)
      # so the Cable touch debounce coalesces bursts locally too.
      @seen_names = Set.new
      @seen_mutex = Mutex.new

      class << self
        # Records a name; returns true if newly seen, false if a duplicate.
        def register_name(name)
          @seen_mutex.synchronize { !@seen_names.add?(name).nil? }
        end

        def clear_seen!
          @seen_mutex.synchronize { @seen_names.clear }
        end
      end

      def enqueue(queue:, path:, body:, schedule_time: nil, name: nil)
        return if name && !self.class.register_name(name)

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
          # No Cloud Run Jobs locally: execute launch envelopes in-process,
          # same as `solid_gcp:execute` would inside the job container.
          when Dispatcher::PERFORM_PATH, Dispatcher::LAUNCH_PATH
            Receiver.receive(envelope)
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
