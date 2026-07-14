# frozen_string_literal: true

module SolidGcp
  # Postgres-backed counting semaphore, mirroring SolidQueue::Semaphore.
  # SQL kept portable across sqlite and postgres.
  class Semaphore < Record
    self.table_name = "solid_gcp_semaphores"

    class << self
      # Returns true if a slot was claimed. Handles the create race: a waiter
      # that loses the INSERT retries the atomic decrement against the winner's row.
      def wait(key, limit:, duration:)
        return true if attempt_decrement(key, duration)
        return true if attempt_create(key, limit, duration)

        attempt_decrement(key, duration)
      end

      # Releases a slot, capped at the configured limit.
      def signal(key, limit:, duration: SolidGcp.config.default_concurrency_duration)
        where(key: key).where("value < ?", limit)
          .update_all(["value = value + 1, expires_at = ?, updated_at = ?", expiry(duration), Time.current])
          .positive?
      end

      # Deletes leases whose holder is presumed dead.
      def expire_stale
        where("expires_at < ?", Time.current).delete_all
      end

      private

      def attempt_create(key, limit, duration)
        create!(key: key, value: limit - 1, expires_at: expiry(duration))
        true
      rescue ActiveRecord::RecordNotUnique
        false
      end

      def attempt_decrement(key, duration)
        where(key: key).where("value > 0")
          .update_all(["value = value - 1, expires_at = ?, updated_at = ?", expiry(duration), Time.current])
          .positive?
      end

      def expiry(duration)
        Time.current + duration
      end
    end
  end
end
