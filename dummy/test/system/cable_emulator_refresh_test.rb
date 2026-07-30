require "application_system_test_case"

# The credential-free twin of cable_live_refresh_test: the same proof (a
# server-side JobRun morphs into the page with no reload) but against the
# Firebase emulators, so CI can run it on every PR.
#
# This is the test that would have caught the bug it is named after: the cable
# controller used to be copied into apps by the generator, the copy went stale,
# and the client subscribed to the "(default)" database while the server wrote to
# a named one. Nothing failed loudly. Two deliberate choices keep that covered:
#
#   * a NAMED database, so the client must actually honor `databaseId` — with the
#     stale client this test times out instead of passing;
#   * no vendored controller anywhere, so what runs here is the file the gem
#     ships (engine importmap pin + app registration, like a real install).
#
# Skipped unless both emulator hosts are set. Locally:
#   docker run --rm -p 8080:8080 -p 9099:9099 \
#     ghcr.io/cruglobal/solid-gcp-firebase-emulators:latest
#   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
#     bin/rails test:system TEST=test/system/cable_emulator_refresh_test.rb
class CableEmulatorRefreshTest < ApplicationSystemTestCase
  DATABASE = "solid-gcp-streams"

  setup do
    unless ENV["FIRESTORE_EMULATOR_HOST"].present? && ENV["FIREBASE_AUTH_EMULATOR_HOST"].present?
      skip "set FIRESTORE_EMULATOR_HOST + FIREBASE_AUTH_EMULATOR_HOST (see the comment above) to run the emulator cable test"
    end

    cable = SolidGcp.config.cable
    @saved = {
      mode: cable.mode, project: cable.project, database: cable.database,
      listen_timeout: cable.listen_timeout
    }
    cable.mode     = :firestore
    cable.project  = "demo-solid-gcp" # Firebase treats demo-* as emulator-only
    cable.database = DATABASE

    SolidGcp::Testing.clear!
    JobRun.delete_all
  end

  teardown do
    next unless @saved

    cable = SolidGcp.config.cable
    cable.mode           = @saved[:mode]
    cable.project        = @saved[:project]
    cable.database       = @saved[:database]
    cable.listen_timeout = @saved[:listen_timeout]
    cable.firestore_emulator_host = nil
  end

  test "a server-side JobRun morphs into the dashboard with no manual reload" do
    visit root_path
    assert_selector "h1", text: "Solid GCP dummy dashboard"
    assert_text "Recent JobRuns (0)"

    # Wait until the listener is live before writing: the controller skips the
    # initial snapshot, so a touch that races ahead of it gets baked into the
    # skipped snapshot and no "changed" callback ever fires.
    wait_for_cable_listening

    JobRun.record!("PingJob", [ 1 ], note: "emulator-refresh")
    SolidGcp::Testing.drain

    # No page.refresh / visit here on purpose.
    assert_text "PingJob", wait: 20
    assert_text "emulator-refresh", wait: 20
    assert_text "Recent JobRuns (1)", wait: 20
  rescue Minitest::Assertion
    dump_browser_logs
    raise
  end

  # The other half of the bug: a listen that never resolves used to be completely
  # silent (console.debug, hidden unless Verbose). A dead Firestore host is the
  # credential-free stand-in for the real cause — a databaseId the project does
  # not have, which the SDK also retries forever without ever erroring out.
  test "a listener that never goes live says so out loud" do
    cable = SolidGcp.config.cable
    cable.listen_timeout = 2.seconds
    cable.firestore_emulator_host = "127.0.0.1:1" # nothing listens here

    visit root_path
    assert_selector "h1", text: "Solid GCP dummy dashboard"
    capture_cable_failures

    detail = wait_for_cable_failure
    assert_equal "#{SolidGcp.config.cable.collection}/#{stream_doc_id}", detail["doc"]
    assert_match(/no snapshot within 2000ms/, detail["error"])

    # ...and visibly, not just as an event: console.error, which a browser shows
    # by default. This is the signal whose absence hid the original bug.
    assert_match(/is not live/, severe_browser_logs.join("\n"))
  rescue Minitest::Assertion
    dump_browser_logs
    raise
  end

  private

  def stream_doc_id
    SolidGcp::Cable::StreamName.doc_id(SolidGcp::Cable::StreamName.from(:job_runs))
  end

  # Block until the cable controller reports at least one live listener (initial
  # snapshot received). Polls the DOM marker the controller sets.
  def wait_for_cable_listening(timeout: 20)
    deadline = Time.now + timeout
    until listening?
      raise Minitest::Assertion, "cable controller never became live (no listener attached within #{timeout}s)" if Time.now > deadline
      sleep 0.1
    end
  end

  def listening?
    count = page.evaluate_script(
      "parseInt(document.documentElement.getAttribute('data-solid-gcp-cable-listening') || '0', 10)"
    )
    count.to_i.positive?
  rescue StandardError
    false
  end

  def capture_cable_failures
    page.execute_script(<<~JS)
      window.solidGcpCableFailures = []
      document.addEventListener("solid-gcp-cable:failed", (event) => {
        window.solidGcpCableFailures.push(event.detail)
      })
    JS
  end

  # Serialized in the browser rather than marshalled object-by-object: the event
  # detail crosses the wire as JSON, which selenium can always carry.
  def wait_for_cable_failure(timeout: 20)
    deadline = Time.now + timeout
    loop do
      failures = JSON.parse(page.evaluate_script("JSON.stringify(window.solidGcpCableFailures || [])"))
      return failures.first if failures.any?
      raise Minitest::Assertion, "no solid-gcp-cable:failed event within #{timeout}s" if Time.now > deadline

      sleep 0.1
    end
  end

  def severe_browser_logs
    page.driver.browser.logs.get(:browser).filter_map { |entry| entry.message if entry.level == "SEVERE" }
  end

  def dump_browser_logs
    logs = page.driver.browser.logs.get(:browser)
    warn "\n--- browser console ---"
    logs.each { |entry| warn "#{entry.level}: #{entry.message}" }
    warn "--- end browser console ---\n"
  rescue StandardError => error
    warn "could not read browser logs: #{error.class}: #{error.message}"
  end
end
