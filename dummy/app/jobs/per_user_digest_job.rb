# Proves on_conflict: :block (the default) + FIFO promotion. Concurrency key is
# per-user, so digests for the same user serialize: a second delivery while the
# first holds the slot is parked in solid_gcp_blocked_jobs and promoted (oldest
# first) when the running job completes and releases the semaphore.
class PerUserDigestJob < ApplicationJob
  limits_concurrency key: ->(user_id) { "digest_#{user_id}" }, to: 1

  def perform(user_id)
    JobRun.record!(self.class.name, arguments, note: "digest start user=#{user_id}")
    sleep 0.2
    JobRun.record!(self.class.name, arguments, note: "digest done user=#{user_id}")
  end
end
