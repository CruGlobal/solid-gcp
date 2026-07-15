# frozen_string_literal: true

module SolidGcp
  # A job that hit its concurrency limit with on_conflict: :block. Promoted FIFO
  # when a slot frees, or re-dispatched by the sweep once its lease expires.
  class BlockedJob < Record
    self.table_name = "solid_gcp_blocked_jobs"

    class << self
      # Promotes the oldest blocked job for the key: dispatch its task + destroy.
      def release_one(key)
        row = where(concurrency_key: key).order(:id).first
        return false unless row

        envelope = JSON.parse(row.serialized_envelope)
        ActiveSupport::Notifications.instrument(
          "promote.solid_gcp",
          concurrency_key: key, job_class: Envelope.job_class_name(envelope)
        ) do
          row.destroy
          Dispatcher.dispatch_envelope(envelope)
        end
        true
      end

      # Re-dispatches expired blocked jobs (they re-attempt the semaphore on delivery).
      def redispatch_expired
        where("expires_at < ?", Time.current).order(:id).each do |row|
          envelope = JSON.parse(row.serialized_envelope)
          row.destroy
          Dispatcher.dispatch_envelope(envelope)
        end
      end
    end
  end
end
