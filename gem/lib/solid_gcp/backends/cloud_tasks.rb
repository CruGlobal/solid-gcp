# frozen_string_literal: true

module SolidGcp
  module Backends
    # Real Cloud Tasks backend. The client is constructor-injectable so tests
    # can assert request shape without touching Google or requiring credentials.
    class CloudTasks
      # config key => the env var the recommended initializer wires it from,
      # surfaced in the ConfigurationError so a missing key is actionable.
      REQUIRED_CONFIG = {
        project: "SOLID_GCP_PROJECT",
        location: "SOLID_GCP_LOCATION",
        push_base_url: "SOLID_GCP_PUSH_BASE_URL",
        invoker_service_account: "SOLID_GCP_INVOKER_SA"
      }.freeze

      def initialize(client: nil, config: SolidGcp.config)
        @injected_client = client
        @config = config
      end

      def enqueue(queue:, path:, body:, schedule_time: nil, name: nil)
        validate_config!
        parent = client.queue_path(
          project: @config.project,
          location: @config.location,
          queue: @config.queue_name(queue)
        )
        client.create_task(parent: parent, task: build_task(parent, path, body, schedule_time, name))
      rescue StandardError => e
        return if already_exists?(e)

        raise
      end

      def build_task(parent, path, body, schedule_time, name)
        task = {
          http_request: {
            http_method: :POST,
            url: "#{@config.push_base_url}#{path}",
            headers: { "Content-Type" => "application/json" },
            body: body,
            oidc_token: {
              service_account_email: @config.invoker_service_account,
              audience: @config.oidc_audience
            }
          }
        }
        task[:schedule_time] = schedule_time.to_time if schedule_time
        task[:name] = "#{parent}/tasks/#{name}" if name
        task
      end

      def client
        @client ||= @injected_client || begin
          require "google/cloud/tasks"
          Google::Cloud::Tasks.cloud_tasks
        end
      end

      private

      # Fail fast with the missing key (and its env var) rather than crashing on
      # a nil deep inside the Cloud Tasks client. Enables tolerant boot-time
      # config (ENV[...] may be nil during asset precompile / image build).
      def validate_config!
        REQUIRED_CONFIG.each do |key, env|
          value = @config.public_send(key)
          next unless value.nil? || (value.respond_to?(:empty?) && value.empty?)

          raise ConfigurationError,
            "SolidGcp.config.#{key} is not set (expected from #{env}); " \
            "cannot enqueue a Cloud Tasks task."
        end
      end

      def already_exists?(error)
        defined?(Google::Cloud::AlreadyExistsError) && error.is_a?(Google::Cloud::AlreadyExistsError)
      end
    end
  end
end
