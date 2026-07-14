# frozen_string_literal: true

module SolidGcp
  # Lazily ensures a single self-scheduled sweep task exists at (roughly) the
  # given time. Deduped per minute-bucket so repeated calls collapse to one task.
  module SweepScheduler
    SWEEP_PATH = "#{MOUNT_PATH}/sweep"

    module_function

    def ensure_scheduled(at:)
      case SolidGcp.config.mode
      when :cloud_tasks then schedule_cloud_task(at)
      when :local       then schedule_local_thread(at)
      when :test        then record_test(at)
      end
    end

    def schedule_cloud_task(at)
      bucket = at.to_i / 60
      Backends::CloudTasks.new.enqueue(
        queue: "default",
        path: SWEEP_PATH,
        body: { "solid_gcp" => Envelope::VERSION, "sweep" => true }.to_json,
        schedule_time: at,
        name: "sweep-#{bucket}"
      )
    end

    def schedule_local_thread(at)
      delay = at - Time.current
      Thread.new do
        sleep([delay, 0].max)
        Rails.application.executor.wrap { Sweep.run }
      end
    end

    def record_test(at)
      Testing.scheduled_sweeps << at
    end
  end
end
