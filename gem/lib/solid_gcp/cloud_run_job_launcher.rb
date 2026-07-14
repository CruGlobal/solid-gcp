# frozen_string_literal: true

module SolidGcp
  # Runs a Cloud Run Job execution passing the serialized envelope via env var.
  # The Cloud Run Job runs the same image with `bin/rails solid_gcp:execute`.
  class CloudRunJobLauncher
    ENVELOPE_ENV = "SOLID_GCP_ENVELOPE"

    def self.launch(envelope, **opts)
      new(**opts).launch(envelope)
    end

    def initialize(client: nil, config: SolidGcp.config)
      @injected_client = client
      @config = config
    end

    def launch(envelope)
      job_class = Envelope.job_class(envelope)
      job_name = (job_class.respond_to?(:cloud_run_job_name) && job_class.cloud_run_job_name) ||
                 @config.cloud_run_job_name
      raise ConfigurationError, "no Cloud Run Job name configured" unless job_name

      client.run_job(
        name: client.job_path(project: @config.project, location: @config.location, job: job_name),
        overrides: {
          container_overrides: [
            { env: [{ name: ENVELOPE_ENV, value: envelope.to_json }] }
          ]
        }
      )
    end

    def client
      @client ||= @injected_client || begin
        require "google/cloud/run/v2"
        Google::Cloud::Run::V2::Jobs::Client.new
      end
    end
  end
end
