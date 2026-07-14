# frozen_string_literal: true

module SolidGcp
  # Idempotently upserts one Cloud Scheduler job per recurring.yml key, each
  # POSTing (OIDC) to /solid_gcp/recurring/<key>. Client is injectable.
  class SchedulerSync
    def initialize(client: nil, config: SolidGcp.config)
      @injected_client = client
      @config = config
    end

    def sync!
      Recurring.load.map do |key, entry|
        upsert(key, entry)
        key
      end
    end

    def upsert(key, entry)
      job = build_job(key, entry)
      client.update_job(job: job)
    rescue StandardError => e
      raise unless not_found?(e)

      client.create_job(parent: location_path, job: job)
    end

    def build_job(key, entry)
      {
        name: job_path(key),
        schedule: Recurring.cron_for(entry),
        http_target: {
          uri: "#{@config.push_base_url}#{MOUNT_PATH}/recurring/#{key}",
          http_method: :POST,
          oidc_token: {
            service_account_email: @config.invoker_service_account,
            audience: @config.oidc_audience
          }
        }
      }
    end

    def job_path(key)
      "#{location_path}/jobs/solid-gcp-#{key}"
    end

    def location_path
      client.location_path(project: @config.project, location: @config.location)
    end

    def client
      @client ||= @injected_client || begin
        require "google/cloud/scheduler"
        Google::Cloud::Scheduler.cloud_scheduler
      end
    end

    private

    def not_found?(error)
      defined?(Google::Cloud::NotFoundError) && error.is_a?(Google::Cloud::NotFoundError)
    end
  end
end
