# DEVELOPMENT ONLY. `perform_via :cloud_run_job` jobs (FakeImportJob) dispatch
# to /launch, which normally calls the Cloud Run Admin API jobs.run — impossible
# without GCP creds. There is no config hook to inject a fake launcher client,
# so for the local demo we reopen the launcher to run the same receiver path
# in-process (exactly what `bin/rails solid_gcp:execute` does on the real Cloud
# Run Job). Production uses the gem's real launcher untouched.
if Rails.env.development? && SolidGcp.config.mode == :local
  module SolidGcp
    class CloudRunJobLauncher
      def self.launch(envelope, **)
        SolidGcp::Receiver.receive(envelope)
      end
    end
  end
end
