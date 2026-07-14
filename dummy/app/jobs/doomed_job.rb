# Always raises an unhandled exception. Proves failed-jobs recording: the
# receiver records a SolidGcp::FailedJob row and reports the error, but still
# returns 2xx (Active Job owns retries; Cloud Tasks must not double-retry).
class DoomedJob < ApplicationJob
  class Doom < StandardError; end

  def perform(reason = "doomed")
    # Write evidence that we ran (and re-ran on retry) before blowing up.
    JobRun.record!(self.class.name, arguments, note: "about to fail: #{reason}")
    raise Doom, reason
  end
end
