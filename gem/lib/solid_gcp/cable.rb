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
    # A REST call to Firestore / IAM Credentials failed (non-2xx after retry, or
    # a network error after retry). Carries the endpoint action for legibility.
    class HttpError < SolidGcp::Error; end

    # Minimal HTTP response wrapper (status + raw body).
    Response = Struct.new(:code, :body)

    OPEN_TIMEOUT = 5  # seconds to establish the connection
    READ_TIMEOUT = 10 # seconds to read the response

    # Transient network failures worth one retry.
    RETRYABLE_EXCEPTIONS = [
      Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError
    ].freeze

    # Default HTTP layer (injectable in tests so nothing hits the network).
    class DefaultHttp
      def post(url, body, headers)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        request = Net::HTTP::Post.new(uri)
        headers.each { |key, value| request[key] = value }
        request.body = body
        response = http.request(request)
        Response.new(response.code.to_i, response.body)
      end
    end

    # Module-level googleauth credential cache, keyed by scope. googleauth
    # credentials cache access tokens internally, so reusing one instance per
    # scope means the token is refreshed only when it actually expires instead of
    # minting a fresh authorizer (and token) on every REST call.
    @authorizers = {}
    @authorizers_mutex = Mutex.new

    module_function

    def config
      SolidGcp.config.cable
    end

    # Memoized application-default credentials for a scope (thread-safe).
    def default_authorizer(scope)
      @authorizers_mutex.synchronize do
        @authorizers[scope] ||= begin
          require "googleauth"
          Google::Auth.get_application_default(scope)
        end
      end
    end

    # Test hook: drop the cached authorizers.
    def reset_authorizers!
      @authorizers_mutex.synchronize { @authorizers.clear }
    end

    # POST via the (injectable) http layer with one jittered retry on transient
    # failures. Returns the Response on 2xx; raises HttpError on a 4xx, on a 5xx
    # that survives the retry, or on a network error that survives the retry.
    # 4xx is never retried (the request itself is bad).
    def request(http, url, body, headers, action:)
      last_attempt = false
      loop do
        begin
          response = http.post(url, body, headers)
          return response if (200..299).cover?(response.code)

          unless server_error?(response.code) && !last_attempt
            raise HttpError, "#{action} failed (#{response.code}): #{body_excerpt(response.body)}"
          end
        rescue *RETRYABLE_EXCEPTIONS => e
          raise HttpError, "#{action} failed after retry (#{e.class}): #{e.message}" if last_attempt
        end

        last_attempt = true
        retry_sleep
      end
    end

    def server_error?(code)
      (500..599).cover?(code)
    end

    def body_excerpt(body)
      body.to_s[0, 500]
    end

    # Small jittered backoff so a pair of racing callers don't retry in lockstep.
    def retry_sleep
      sleep(0.05 + rand * 0.1)
    end

    # Synchronously bump the stream doc. No-op unless enabled.
    def touch(*streamables)
      case config.mode
      when :firestore
        return unless firestore_ready?

        stream_name = StreamName.from(*streamables)
        instrument_touch(stream_name, sync: true, debounced: false) do
          Firestore.new.touch(stream_name)
        end
      when :test
        stream_name = StreamName.from(*streamables)
        instrument_touch(stream_name, sync: true, debounced: false) do
          TestSink.record(stream_name)
        end
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
        stream_name = StreamName.from(*streamables)
        instrument_touch(stream_name, sync: false, debounced: false) do
          TouchJob.perform_later(*streamables)
        end
      when :firestore
        return unless firestore_ready?

        stream_name = StreamName.from(*streamables)
        debounced = debounce_active?
        instrument_touch(stream_name, sync: false, debounced: debounced) do
          if debounced
            enqueue_debounced(streamables)
          else
            TouchJob.perform_later(*streamables)
          end
        end
      end
      nil
    end

    # touch.solid_gcp: stream name, doc id, sync (touch) vs later (touch_later),
    # and whether the later path is debounce-deduped.
    def instrument_touch(stream_name, sync:, debounced:)
      ActiveSupport::Notifications.instrument(
        "touch.solid_gcp",
        stream: stream_name, doc_id: StreamName.doc_id(stream_name),
        sync: sync, debounced: debounced
      ) do
        yield
      end
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