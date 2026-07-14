# frozen_string_literal: true

module SolidGcp
  # `perform_via` DSL selecting how a job is executed on delivery.
  #   perform_via :http_push                          (default)
  #   perform_via :cloud_run_job
  #   perform_via :cloud_run_job, job: "import-runner"
  module ExecutionMode
    extend ActiveSupport::Concern

    included do
      class_attribute :execution_mode, instance_accessor: false, default: :http_push
      class_attribute :cloud_run_job_name, instance_accessor: false, default: nil
    end

    class_methods do
      def perform_via(mode, job: nil)
        unless %i[http_push cloud_run_job].include?(mode)
          raise ArgumentError, "execution mode must be :http_push or :cloud_run_job"
        end

        self.execution_mode = mode
        self.cloud_run_job_name = job if job
      end

      def cloud_run_job?
        execution_mode == :cloud_run_job
      end
    end
  end
end
