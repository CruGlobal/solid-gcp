# Proves the retry ladder. Fails the first two attempts, succeeds on the third.
# retry_on re-enqueues itself as a new Cloud Tasks task with a growing
# scheduleTime (:polynomially_longer); the `executions` counter rides in the
# serialized job, so Active Job retry semantics work unmodified on the adapter.
class FlakyWebhookJob < ApplicationJob
  class DeliveryError < StandardError; end

  retry_on DeliveryError, wait: :polynomially_longer, attempts: 5

  def perform(url = "https://example.test/hook")
    # `executions` is 1 on the first attempt, 2 on the second, etc.
    if executions < 3
      raise DeliveryError, "transient delivery failure (attempt #{executions})"
    end

    JobRun.record!(self.class.name, arguments, note: "delivered on attempt #{executions} to #{url}")
  end
end
