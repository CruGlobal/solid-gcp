# frozen_string_literal: true

module SolidGcp
  # The JSON task body shared by /perform, /launch and the Cloud Run Job env var:
  #   { "solid_gcp": 1, "job": { ...ActiveJob#serialize... }, "dispatched_at": iso8601 }
  module Envelope
    VERSION = 1

    module_function

    def build(job)
      {
        "solid_gcp" => VERSION,
        "job" => job.serialize,
        "dispatched_at" => Time.now.utc.iso8601
      }
    end

    def job_data(envelope)
      envelope.fetch("job")
    end

    def job_class(envelope)
      job_class_name(envelope).constantize
    end

    # Class name as a String (no constantize) — cheap, safe for error messages
    # and instrumentation payloads.
    def job_class_name(envelope)
      job_data(envelope).fetch("job_class")
    end
  end
end
