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
      stream_name = StreamName.from(*streamables)

      case config.mode
      when :firestore then Firestore.new.touch(stream_name)
      when :test      then TestSink.record(stream_name)
      end
      nil
    end

    # Enqueue a TouchJob onto the queue component. No-op when disabled.
    def touch_later(*streamables)
      return if config.mode == :off

      TouchJob.perform_later(*streamables)
    end
  end
end