class JobRun < ApplicationRecord
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
