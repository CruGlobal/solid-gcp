# frozen_string_literal: true

module SolidGcp
  # Builds envelopes and routes them to the configured backend. Chooses the
  # target endpoint (/perform vs /launch) from the job's execution mode.
  module Dispatcher
    PERFORM_PATH = "#{MOUNT_PATH}/perform"
    LAUNCH_PATH  = "#{MOUNT_PATH}/launch"

    module_function

    # From an ActiveJob instance (enqueue path). `name:` requests a Cloud Tasks
    # named task (backend-deduped), used by the Cable touch debounce.
    def dispatch(job, at: nil, name: nil)
      ActiveSupport::Notifications.instrument(
        "enqueue.solid_gcp",
        job_class: job.class.name, queue: job.queue_name, at: at, named: !name.nil?
      ) do
        envelope = Envelope.build(job)
        enqueue(envelope,
                queue: job.queue_name,
                path: path_for(job.class),
                at: at,
                name: name)
      end
    end

    # From an existing envelope (blocked-job promotion, failed-job retry).
    def dispatch_envelope(envelope, at: nil)
      job_data = Envelope.job_data(envelope)
      ActiveSupport::Notifications.instrument(
        "enqueue.solid_gcp",
        job_class: job_data["job_class"], queue: job_data.fetch("queue_name"), at: at, named: false
      ) do
        enqueue(envelope,
                queue: job_data.fetch("queue_name"),
                path: path_for(Envelope.job_class(envelope)),
                at: at)
      end
    end

    def enqueue(envelope, queue:, path:, at: nil, name: nil)
      body = envelope.to_json
      check_payload_size!(envelope, body) if SolidGcp.config.mode == :cloud_tasks
      backend.enqueue(
        queue: queue,
        path: path,
        body: body,
        schedule_time: at,
        name: name
      )
    end

    # Cloud Tasks rejects tasks whose total size exceeds ~1 MB. Guard at enqueue
    # so an oversized argument fails fast and legibly instead of as an opaque
    # RPC error deep in the backend.
    def check_payload_size!(envelope, body)
      max = SolidGcp.config.max_task_bytes
      size = body.bytesize
      return if size <= max

      raise PayloadTooLarge,
        "#{Envelope.job_class_name(envelope)} envelope is #{size} bytes, " \
        "over max_task_bytes=#{max} (Cloud Tasks caps total task size near 1 MB). " \
        "Pass an id/reference instead of inlining large data."
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
