# Trivial job: writes a JobRun row so an execution is observable.
class PingJob < ApplicationJob
  def perform(note = "ping")
    JobRun.record!(self.class.name, arguments, note: note)
  end
end
