# Proves on_conflict: :discard. Only one may hold the "singleton_tick"
# semaphore at a time; a second delivery while the first is running is dropped
# silently at delivery time.
class SingletonTickJob < ApplicationJob
  limits_concurrency key: "singleton_tick", to: 1, on_conflict: :discard

  def perform
    JobRun.record!(self.class.name, arguments, note: "tick start")
    sleep 0.2 # hold the semaphore briefly so a concurrent delivery is discarded
    JobRun.record!(self.class.name, arguments, note: "tick done")
  end
end
