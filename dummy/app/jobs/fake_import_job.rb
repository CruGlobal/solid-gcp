# The Cloud Run Jobs candidate (a stand-in for Flightdeck's jira-import).
# perform_via :cloud_run_job routes its Cloud Tasks task to /launch, which runs
# the Cloud Run Admin API jobs.run against the same image with the command
# `bin/rails solid_gcp:execute`. That entrypoint runs this exact #perform via
# the receiver path. Here it just loops N iterations writing progress rows.
class FakeImportJob < ApplicationJob
  perform_via :cloud_run_job # uses config.solid_gcp.cloud_run_job_name

  def perform(iterations = 5, import_id: SecureRandom.hex(4))
    JobRun.record!(self.class.name, arguments, note: "import #{import_id} started (#{iterations} steps)")
    iterations.times do |i|
      sleep 0.05
      JobRun.record!(self.class.name, arguments, note: "import #{import_id} progress #{i + 1}/#{iterations}")
    end
    JobRun.record!(self.class.name, arguments, note: "import #{import_id} complete")
  end
end
