# Proves on_conflict: :discard. Only one may hold the "singleton_tick"
# semaphore at a time; a second delivery while the first is running is dropped
# silently at delivery time.
class SingletonTickJob < ApplicationJob
  limits_concurrency key: "singleton_tick", to: 1, on_conflict: :discard

  def perform
    JobRun.record!(self.class.name, arguments, note: "tick start")
    # Hold the semaphore so a concurrent delivery is discarded. Default 0.2s;
    # override with DEMO_HOLD_SECONDS to exceed real Cloud Tasks dispatch spacing
    # when proving the conflict path on a live deployment.
    sleep Float(ENV.fetch("DEMO_HOLD_SECONDS", "0.2"))
    JobRun.record!(self.class.name, arguments, note: "tick done")
  end
end
