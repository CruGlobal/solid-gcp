# frozen_string_literal: true

module SolidGcp
  # An unhandled job failure (not covered by retry_on/discard_on). Mirrors
  # Solid Queue's failed_executions; supports retry/discard.
  class FailedJob < Record
    self.table_name = "solid_gcp_failed_jobs"

    def self.record!(envelope, error)
      job = Envelope.job_data(envelope)
      create!(
        active_job_id: job["job_id"],
        job_class: job["job_class"],
        queue_name: job["queue_name"],
        serialized_envelope: envelope.to_json,
        error_class: error.class.name,
        error_message: error.message,
        backtrace: Array(error.backtrace).join("\n"),
        failed_at: Time.current
      )
    end

    # Re-dispatches the original envelope and removes the failed record.
    def retry_job
      Dispatcher.dispatch_envelope(JSON.parse(serialized_envelope))
      destroy
    end

    def discard
      destroy
    end
  end
end
