require "application_system_test_case"

# The real proof for SolidGcp::Cable: with cable in :firestore mode against a
# live Firestore, creating a JobRun server-side must make the browser's
# dashboard morph in the new row WITHOUT a manual reload.
#
# SKIPPED unless SOLID_GCP_CABLE_E2E is set (it needs GCP creds + a live
# Firestore/Firebase project). Required env:
#   SOLID_GCP_CABLE_E2E=1                       # gate
#   SOLID_GCP_CABLE_PROJECT=cru-mattdrees-sandbox-poc
#   SOLID_GCP_CABLE_FIREBASE_WEB_CONFIG='{"apiKey":"...","authDomain":"...","projectId":"cru-mattdrees-sandbox-poc",...}'
#   SOLID_GCP_CABLE_SIGNER_EMAIL=<SA that can sign its own blobs>   # optional if ADC SA can
#   GOOGLE_APPLICATION_CREDENTIALS / ADC        # for Firestore write + IAM signBlob
#
# Run with:
#   SOLID_GCP_CABLE_E2E=1 \
#   SOLID_GCP_CABLE_PROJECT=cru-mattdrees-sandbox-poc \
#   SOLID_GCP_CABLE_FIREBASE_WEB_CONFIG='{...}' \
#   SOLID_GCP_CABLE_SIGNER_EMAIL=<sa> \
#   bin/rails test:system TEST=test/system/cable_live_refresh_test.rb
class CableLiveRefreshTest < ApplicationSystemTestCase
  setup do
    skip "set SOLID_GCP_CABLE_E2E to run the live Firestore cable test" unless ENV["SOLID_GCP_CABLE_E2E"].present?

    cable = SolidGcp.config.cable
    @saved = {
      mode: cable.mode, project: cable.project,
      web: cable.firebase_web_config, signer: cable.signer_email
    }
    cable.mode                = :firestore
    cable.project             = ENV.fetch("SOLID_GCP_CABLE_PROJECT")
    cable.firebase_web_config = JSON.parse(ENV.fetch("SOLID_GCP_CABLE_FIREBASE_WEB_CONFIG"))
    cable.signer_email        = ENV["SOLID_GCP_CABLE_SIGNER_EMAIL"]

    SolidGcp::Testing.clear!
    JobRun.delete_all
  end

  teardown do
    next unless @saved

    cable = SolidGcp.config.cable
    cable.mode                = @saved[:mode]
    cable.project             = @saved[:project]
    cable.firebase_web_config = @saved[:web]
    cable.signer_email        = @saved[:signer]
  end

  test "a server-side JobRun morphs into the dashboard with no manual reload" do
    visit root_path
    assert_selector "h1", text: "Solid GCP dummy dashboard"
    # Wait for the JobRuns section to be present; start from a known-empty state.
    assert_text "Recent JobRuns (0)"

    # Create a JobRun the way a completed demo job would, then run the enqueued
    # TouchJob so it bumps the live Firestore stream doc. (solid_gcp is :test in
    # this env, so we drain explicitly rather than relying on push delivery.)
    JobRun.record!("PingJob", [ 1 ], note: "live-refresh")
    SolidGcp::Testing.drain

    # No page.refresh / visit here on purpose: the Firestore onSnapshot ->
    # Turbo morph refresh must surface the new row on its own.
    assert_text "PingJob", wait: 20
    assert_text "live-refresh", wait: 20
    assert_text "Recent JobRuns (1)", wait: 20
  rescue Minitest::Assertion
    dump_browser_logs
    raise
  end

  private

  def dump_browser_logs
    logs = page.driver.browser.logs.get(:browser)
    warn "\n--- browser console ---"
    logs.each { |entry| warn "#{entry.level}: #{entry.message}" }
    warn "--- end browser console ---\n"
  rescue StandardError => error
    warn "could not read browser logs: #{error.class}: #{error.message}"
  end
end
