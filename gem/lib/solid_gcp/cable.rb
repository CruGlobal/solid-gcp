# frozen_string_literal: true

require "digest"
require "base64"
require "net/http"
require "uri"
require "json"

require "solid_gcp/cable/stream_name"
require "solid_gcp/cable/test_sink"
require "solid_gcp/cable/firestore"
require "solid_gcp/cable/custom_token"

module SolidGcp
  # Optional realtime component: bumps a per-stream Firestore doc so a Stimulus
  # controller can trigger a Turbo morph refresh. Fully no-op unless
  # `SolidGcp.config.cable.mode` is :firestore or :test.
  module Cable
    # Minimal HTTP response wrapper (status + raw body).
    Response = Struct.new(:code, :body)

    # Default HTTP layer (injectable in tests so nothing hits the network).
    class DefaultHttp
      def post(url, body, headers)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        request = Net::HTTP::Post.new(uri)
        headers.each { |key, value| request[key] = value }
        request.body = body
        response = http.request(request)
        Response.new(response.code.to_i, response.body)
      end
    end

    module_function

    def config
      SolidGcp.config.cable
    end

    # Synchronously bump the stream doc. No-op unless enabled.
    def touch(*streamables)
      case config.mode
      when :firestore
        return unless firestore_ready?

        Firestore.new.touch(StreamName.from(*streamables))
      when :test
        TestSink.record(StreamName.from(*streamables))
      end
      nil
    end

    # Enqueue a TouchJob onto the queue component. No-op when disabled.
    #
    # In :firestore mode with an active `touch_debounce`, the job is dispatched
    # as a Cloud Tasks named task scheduled at the next debounce bucket boundary;
    # duplicate touches in the window collide on the task name and are dropped
    # (trailing-edge coalescing). :test/:off keep their prior behavior.
    def touch_later(*streamables)
      case config.mode
      when :off
        nil
      when :test
        TouchJob.perform_later(*streamables)
      when :firestore
        return unless firestore_ready?

        if debounce_active?
          enqueue_debounced(streamables)
        else
          TouchJob.perform_later(*streamables)
        end
      end
      nil
    end

    # --- debounce internals ------------------------------------------------

    def debounce_active?
      debounce = config.touch_debounce
      !debounce.nil? && debounce.to_f > 0
    end

    # Dispatch TouchJob as a named task at the trailing bucket boundary. The
    # name embeds the bucket so it is never reused; ALREADY_EXISTS (cloud_tasks)
    # / seen-name (local) collisions are swallowed by the backend.
    def enqueue_debounced(streamables)
      stream_name = StreamName.from(*streamables)
      doc_id = StreamName.doc_id(stream_name)
      bucket_ms = debounce_bucket_ms(Time.now.to_f, config.touch_debounce.to_f)

      Dispatcher.dispatch(
        TouchJob.new(*streamables),
        at: Time.at(bucket_ms / 1000.0).utc,
        name: task_name(doc_id, bucket_ms)
      )
    end

    # Next debounce boundary in integer epoch-ms: ((now / d).floor + 1) * d.
    # Integer-ms math keeps it deterministic and free of float dust.
    def debounce_bucket_ms(now, debounce)
      now_ms = (now * 1000).round
      d_ms = (debounce * 1000).round
      ((now_ms / d_ms) + 1) * d_ms
    end

    # `sgc-touch-<doc id first 16 hex>-<bucket epoch>`. Sub-second buckets render
    # the fractional epoch with the dot swapped for a hyphen (task-name-safe).
    def task_name(doc_id, bucket_ms)
      epoch = (bucket_ms % 1000).zero? ? (bucket_ms / 1000).to_s : (bucket_ms / 1000.0).to_s.tr(".", "-")
      "sgc-touch-#{doc_id[0, 16]}-#{epoch}"
    end

    # --- project resolution / warn-once -----------------------------------

    # True when a Firestore project resolves. Otherwise warns once per process
    # and returns false so bare dev apps (default-on, no project) keep working.
    def firestore_ready?
      return true if config.project

      warn_missing_project unless @warned_missing_project
      @warned_missing_project = true
      false
    end

    def warn_missing_project
      message = "[solid_gcp] cable.mode=:firestore but no project resolves " \
                "(set config.solid_gcp.cable.project or config.solid_gcp.project); " \
                "touch/touch_later will no-op"
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        Kernel.warn(message)
      end
    end

    # Test hook: reset the once-per-process warning latch.
    def reset_missing_project_warning!
      @warned_missing_project = false
    end
  end
end