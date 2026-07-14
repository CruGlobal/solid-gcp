# frozen_string_literal: true

module SolidGcp
  # Runtime configuration. In a Rails app this object is exposed as
  # `config.solid_gcp` so `config.solid_gcp.mode = :local` mutates it directly.
  class Configuration
    attr_accessor :project, :location, :push_base_url,
                  :invoker_service_account, :default_concurrency_duration,
                  :cloud_run_job_name, :connects_to, :recurring_file
    attr_accessor :queue_prefix
    attr_writer :mode, :oidc_audience, :verify_oidc

    def initialize
      @mode = :cloud_tasks
      @queue_prefix = "solid-gcp-"
      @default_concurrency_duration = 15.minutes
      @recurring_file = "config/recurring.yml"
      @oidc_audience = nil
      @verify_oidc = nil
    end

    attr_reader :mode

    # Defaults to push_base_url when not set explicitly.
    def oidc_audience
      @oidc_audience || push_base_url
    end

    # Defaults to true only in production; false everywhere else (dev/test/local).
    def verify_oidc
      return @verify_oidc unless @verify_oidc.nil?

      defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.production? : true
    end

    def queue_name(active_job_queue)
      "#{queue_prefix}#{active_job_queue}"
    end

    # Cable (Firestore-backed Turbo refresh) sub-config. No-op unless mode set.
    def cable
      @cable ||= CableConfiguration.new(self)
    end

    # Optional realtime-refresh component. Defaults keep it fully off and
    # network-free until `mode` is set to :firestore or :test.
    class CableConfiguration
      attr_accessor :database, :collection, :signer_email,
                    :firebase_web_config, :stream_ttl, :token_ttl,
                    :touch_debounce
      attr_writer :mode, :project

      def initialize(parent)
        @parent = parent
        @mode = :firestore
        @database = "(default)"
        @collection = "solid_gcp_streams"
        @signer_email = nil
        @firebase_web_config = {}
        @stream_ttl = 30.days
        @token_ttl = 55.minutes
        @touch_debounce = 1.second
      end

      attr_reader :mode

      # Defaults to the queue component's project when not set explicitly.
      def project
        @project || @parent.project
      end
    end
  end
end
