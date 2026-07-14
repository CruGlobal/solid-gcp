# frozen_string_literal: true

module SolidGcp
  # Crash-safety maintenance: expire stale semaphores, re-dispatch expired
  # blocked jobs, and reschedule itself if any leased rows remain.
  module Sweep
    module_function

    def run
      Semaphore.expire_stale
      BlockedJob.redispatch_expired
      reschedule_if_outstanding
    end

    def reschedule_if_outstanding
      next_expiry = [Semaphore.minimum(:expires_at), BlockedJob.minimum(:expires_at)].compact.min
      SweepScheduler.ensure_scheduled(at: next_expiry) if next_expiry
    end
  end
end
