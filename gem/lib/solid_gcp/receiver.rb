# frozen_string_literal: true

module SolidGcp
  # Executes a delivered envelope: concurrency gate -> ActiveJob execute ->
  # semaphore release + blocked-job promotion (always, even on failure).
  #
  # Returns one of :executed, :discarded, :blocked. Raises SolidGcp::NotReady
  # for infra-not-ready conditions (controller maps that to 503).
  class Receiver
    def self.receive(envelope)
      new(envelope).receive
    end

    def initialize(envelope)
      @envelope = envelope
      @job_data = Envelope.job_data(envelope)
    end

    def receive
      job = ActiveJob::Base.deserialize(@job_data)
      job.send(:deserialize_arguments_if_needed)

      acquired = false
      key = nil
      limit = nil

      klass = job.class
      if klass.respond_to?(:concurrency_limited?) && klass.concurrency_limited?
        key = job.concurrency_key
        limit = klass.concurrency_limit
        duration = klass.concurrency_duration

        acquired = Semaphore.wait(key, limit: limit, duration: duration)
        unless acquired
          case klass.concurrency_on_conflict
          when :discard
            return :discarded
          when :block
            BlockedJob.create!(
              concurrency_key: key,
              serialized_envelope: @envelope.to_json,
              expires_at: Time.current + duration
            )
            SweepScheduler.ensure_scheduled(at: Time.current + duration)
            return :blocked
          end
        end

        SweepScheduler.ensure_scheduled(at: Time.current + duration)
      end

      execute
    ensure
      if acquired
        Semaphore.signal(key, limit: limit)
        BlockedJob.release_one(key)
      end
    end

    private

    def execute
      ActiveJob::Base.execute(@job_data)
      :executed
    rescue StandardError => e
      raise NotReady, e.message if infra_error?(e) && !e.is_a?(NotReady)
      raise if e.is_a?(NotReady)

      FailedJob.record!(@envelope, e)
      Rails.error.report(e, handled: false) if defined?(Rails) && Rails.respond_to?(:error)
      :executed
    end

    def infra_error?(error)
      return true if error.is_a?(SolidGcp::NotReady)
      return true if defined?(ActiveRecord::ConnectionNotEstablished) &&
                     error.is_a?(ActiveRecord::ConnectionNotEstablished)
      return true if defined?(ActiveRecord::NoDatabaseError) &&
                     error.is_a?(ActiveRecord::NoDatabaseError)

      # PG::ConnectionBad et al. without hard-depending on the pg gem.
      error.class.name.start_with?("PG::") &&
        %w[ConnectionBad UnableToSend ConnectionException].any? { |n| error.class.name.include?(n) }
    end
  end
end
