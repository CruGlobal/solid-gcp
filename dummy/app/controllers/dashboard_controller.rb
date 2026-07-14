# Minimal dashboard proving the gem end-to-end: enqueue demo jobs, watch
# JobRuns appear (in development :local mode delays actually elapse), inspect
# failed jobs and retry them.
class DashboardController < ApplicationController
  # Each demo button maps to a zero-config enqueue.
  DEMOS = {
    "ping"        => -> { PingJob.perform_later("from dashboard") },
    "flaky"       => -> { FlakyWebhookJob.perform_later },
    "doomed"      => -> { DoomedJob.perform_later("dashboard doom") },
    "singleton"   => -> { 3.times { SingletonTickJob.perform_later } },
    "digest"      => -> { 3.times { PerUserDigestJob.perform_later(42) } },
    "escalation"  => -> { EscalationStepJob.perform_later(1) },
    "import"      => -> { FakeImportJob.perform_later(5) }
  }.freeze

  def index
    @job_runs = JobRun.order(ran_at: :desc, id: :desc).limit(40)
    @failed_jobs = SolidGcp::FailedJob.order(failed_at: :desc).limit(20)
    @mode = SolidGcp.config.mode
  end

  def enqueue
    demo = DEMOS[params[:job]]
    if demo
      demo.call
      redirect_to root_path, notice: "Enqueued #{params[:job]} (mode: #{SolidGcp.config.mode})."
    else
      redirect_to root_path, alert: "Unknown demo: #{params[:job]}"
    end
  end

  def retry_failed
    SolidGcp::FailedJob.find(params[:id]).retry_job
    redirect_to root_path, notice: "Re-dispatched failed job ##{params[:id]}."
  end
end
