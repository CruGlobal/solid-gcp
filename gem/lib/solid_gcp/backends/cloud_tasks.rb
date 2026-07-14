# frozen_string_literal: true

module SolidGcp
  module Backends
    # Real Cloud Tasks backend. The client is constructor-injectable so tests
    # can assert request shape without touching Google or requiring credentials.
    class CloudTasks
      def initialize(client: nil, config: SolidGcp.config)
        @injected_client = client
        @config = config
      end

      def enqueue(queue:, path:, body:, schedule_time: nil, name: nil)
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

      def already_exists?(error)
        defined?(Google::Cloud::AlreadyExistsError) && error.is_a?(Google::Cloud::AlreadyExistsError)
      end
    end
  end
end
