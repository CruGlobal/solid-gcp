# frozen_string_literal: true

namespace :solid_gcp do
  desc "Execute a serialized job envelope from ENV['SOLID_GCP_ENVELOPE'] (Cloud Run Job entrypoint)"
  task execute: :environment do
    require "solid_gcp"

    raw = ENV["SOLID_GCP_ENVELOPE"]
    abort("SOLID_GCP_ENVELOPE not set") if raw.nil? || raw.empty?

    envelope = JSON.parse(raw)
    begin
      SolidGcp::Receiver.receive(envelope)
    rescue SolidGcp::NotReady => e
      warn("[solid_gcp:execute] infra not ready: #{e.message}")
      exit(1) # non-zero so the Cloud Run Job execution retries
    end
  end

  namespace :scheduler do
    desc "Idempotently sync recurring.yml entries to Cloud Scheduler"
    task sync: :environment do
      require "solid_gcp"
      keys = SolidGcp::SchedulerSync.new.sync!
      puts "Synced #{keys.size} Cloud Scheduler job(s): #{keys.join(', ')}"
    end
  end
end
