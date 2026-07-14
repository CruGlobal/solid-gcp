# frozen_string_literal: true

module SolidGcp
  # Builds envelopes and routes them to the configured backend. Chooses the
  # target endpoint (/perform vs /launch) from the job's execution mode.
  module Dispatcher
    PERFORM_PATH = "#{MOUNT_PATH}/perform"
    LAUNCH_PATH  = "#{MOUNT_PATH}/launch"

    module_function

    # From an ActiveJob instance (enqueue path).
    def dispatch(job, at: nil)
      envelope = Envelope.build(job)
      enqueue(envelope,
              queue: job.queue_name,
              path: path_for(job.class),
              at: at)
    end

    # From an existing envelope (blocked-job promotion, failed-job retry).
    def dispatch_envelope(envelope, at: nil)
      job_data = Envelope.job_data(envelope)
      enqueue(envelope,
              queue: job_data.fetch("queue_name"),
              path: path_for(Envelope.job_class(envelope)),
              at: at)
    end

    def enqueue(envelope, queue:, path:, at: nil, name: nil)
      backend.enqueue(
        queue: queue,
        path: path,
        body: envelope.to_json,
        schedule_time: at,
        name: name
      )
    end

    def path_for(job_class)
      job_class.respond_to?(:cloud_run_job?) && job_class.cloud_run_job? ? LAUNCH_PATH : PERFORM_PATH
    end

    def backend
      case SolidGcp.config.mode
      when :cloud_tasks then Backends::CloudTasks.new
      when :local       then Backends::Local.new
      when :test        then Backends::Test.new
      else
        raise ConfigurationError, "unknown SolidGcp mode: #{SolidGcp.config.mode.inspect}"
      end
    end
  end
end
