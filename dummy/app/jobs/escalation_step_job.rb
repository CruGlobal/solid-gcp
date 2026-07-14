# Proves delayed enqueue (set(wait:) -> Cloud Tasks scheduleTime). Each step
# writes a JobRun then self-reschedules the next step 5 seconds out, up to 3.
class EscalationStepJob < ApplicationJob
  MAX_STEP = 3

  def perform(step = 1)
    JobRun.record!(self.class.name, arguments, note: "escalation step #{step}/#{MAX_STEP}")
    return if step >= MAX_STEP

    self.class.set(wait: 5.seconds).perform_later(step + 1)
  end
end
