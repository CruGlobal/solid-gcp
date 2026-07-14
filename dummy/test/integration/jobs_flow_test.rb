require "test_helper"

# Exercises the demo jobs through the :test backend (config.solid_gcp.mode
# = :test in config/environments/test.rb). Enqueue records an in-memory
# envelope; SolidGcp::Testing.drain runs pending /perform + /launch envelopes
# (including retries/promotions enqueued during draining).
class JobsFlowTest < ActiveSupport::TestCase
  # Draining runs jobs synchronously on this connection, so it must not race
  # parallel workers; keep it simple and serial.
  self.use_transactional_tests = true

  setup do
    SolidGcp::Testing.clear!
  end

  # --- helpers ---------------------------------------------------------------

  def enqueued = SolidGcp::Testing.enqueued
  def drain    = SolidGcp::Testing.drain

  def receive(job) = SolidGcp::Receiver.receive(SolidGcp::Envelope.build(job))
  def receive_envelope(env) = SolidGcp::Receiver.receive(env)

  # --- PingJob ---------------------------------------------------------------

  test "PingJob enqueues and runs, writing a JobRun" do
    PingJob.perform_later("hi")
    assert_equal 1, enqueued.size
    assert_equal "/solid_gcp/perform", enqueued.first[:path]

    drain
    assert_equal 1, JobRun.where(job_class: "PingJob").count
  end

  # --- FlakyWebhookJob: retry ladder -----------------------------------------

  test "FlakyWebhookJob succeeds after retries with growing scheduled times" do
    FlakyWebhookJob.perform_later
    attempt1 = enqueued.shift

    # Attempt 1 fails -> retry_on schedules a new task in the future.
    receive_envelope(attempt1[:envelope])
    retry1 = enqueued.shift
    refute_nil retry1[:schedule_time], "first retry should be scheduled in the future"
    delay1 = retry1[:schedule_time].to_f - Time.now.to_f
    assert_equal 1, retry1[:envelope]["job"]["executions"]

    # Attempt 2 fails -> schedules again, with a larger (polynomial) wait.
    receive_envelope(retry1[:envelope])
    retry2 = enqueued.shift
    delay2 = retry2[:schedule_time].to_f - Time.now.to_f
    assert_equal 2, retry2[:envelope]["job"]["executions"]
    assert_operator delay2, :>, delay1, "wait should grow between retries"

    # Attempt 3 succeeds.
    receive_envelope(retry2[:envelope])
    assert_empty enqueued, "no further retries after success"
    assert_equal 1, JobRun.where(job_class: "FlakyWebhookJob").count
    assert_equal 0, SolidGcp::FailedJob.count
  end

  # --- DoomedJob: failed-jobs recording + retry ------------------------------

  test "DoomedJob lands in solid_gcp_failed_jobs and retry_job re-runs it" do
    DoomedJob.perform_later("kaboom")
    drain

    assert_equal 1, SolidGcp::FailedJob.count
    assert_equal 1, JobRun.where(job_class: "DoomedJob").count, "ran once"
    failed = SolidGcp::FailedJob.first
    assert_equal "DoomedJob", failed.job_class
    assert_equal "DoomedJob::Doom", failed.error_class

    # Retry re-dispatches the original envelope and clears the failed record.
    failed.retry_job
    assert_equal 0, SolidGcp::FailedJob.count
    drain

    assert_equal 1, SolidGcp::FailedJob.count, "re-run failed again -> new record"
    assert_equal 2, JobRun.where(job_class: "DoomedJob").count, "ran twice total"
  end

  # --- SingletonTickJob: on_conflict :discard --------------------------------

  test "SingletonTickJob second delivery is discarded while first holds the slot" do
    # Simulate the first tick holding the only semaphore slot.
    assert SolidGcp::Semaphore.wait("singleton_tick", limit: 1, duration: 60)

    assert_equal :discarded, receive(SingletonTickJob.new)
    assert_equal 0, JobRun.where(job_class: "SingletonTickJob").count
  end

  # --- PerUserDigestJob: on_conflict :block + FIFO promotion ------------------

  test "PerUserDigestJob blocks a second delivery and promotes FIFO on completion" do
    # A running digest for user 5 holds the only slot.
    assert SolidGcp::Semaphore.wait("digest_5", limit: 1, duration: 60)

    first  = PerUserDigestJob.new(5)
    second = PerUserDigestJob.new(5)
    assert_equal :blocked, receive(first)
    assert_equal :blocked, receive(second)
    assert_equal 2, SolidGcp::BlockedJob.where(concurrency_key: "digest_5").count

    # Different user -> different key -> not blocked, runs immediately.
    assert_equal :executed, receive(PerUserDigestJob.new(6))
    assert_equal 1, JobRun.where("note LIKE ?", "%done user=6%").count

    # Running job completes: release the slot and promote blocked jobs (this is
    # exactly what the receiver's ensure-block does on normal completion).
    assert SolidGcp::Semaphore.signal("digest_5", limit: 1)
    SolidGcp::BlockedJob.release_one("digest_5")
    SolidGcp::BlockedJob.release_one("digest_5")

    promoted_ids = enqueued.map { |t| t[:envelope]["job"]["job_id"] }
    assert_equal [first.job_id, second.job_id], promoted_ids, "oldest promoted first"
    assert_equal 0, SolidGcp::BlockedJob.count
  end

  # --- EscalationStepJob: delayed self-reschedule ----------------------------

  test "EscalationStepJob self-reschedules the next step with a wait" do
    EscalationStepJob.perform_later(1)
    step1 = enqueued.shift
    assert_nil step1[:schedule_time], "first step is immediate"

    receive_envelope(step1[:envelope])
    step2 = enqueued.shift
    refute_nil step2[:schedule_time], "next step scheduled in the future"
    assert_operator step2[:schedule_time].to_f - Time.now.to_f, :>, 3
    assert_equal [2], step2[:envelope]["job"]["arguments"]
    assert_equal 1, JobRun.where(job_class: "EscalationStepJob").count
  end

  # --- FakeImportJob: cloud_run_job routing ----------------------------------

  test "FakeImportJob routes its task to /launch (Cloud Run Jobs mode)" do
    FakeImportJob.perform_later(2)
    task = enqueued.first
    assert_equal "/solid_gcp/launch", task[:path],
      "perform_via :cloud_run_job must target /launch, not /perform"
  end
end
