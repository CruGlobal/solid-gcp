class JobRun < ApplicationRecord
  # Realtime demo: bump the :job_runs stream so subscribed dashboards morph in
  # the new row. No-ops unless SolidGcp.config.cable.mode is set (touch_later
  # returns early when mode is :off), so this is free for queue-only adopters.
  after_create_commit { SolidGcp::Cable.touch_later(:job_runs) }

  # Observable evidence that a job actually executed. Demo jobs write a row
  # (with an optional note) every time their #perform runs.
  def self.record!(job_class, args = [], note: nil)
    create!(
      job_class: job_class.to_s,
      args: Array(args).inspect,
      note: note,
      ran_at: Time.current
    )
  end
end
