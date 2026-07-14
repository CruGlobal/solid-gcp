# frozen_string_literal: true

module SolidGcp
  # `limits_concurrency` DSL, mirroring Solid Queue's API. Included into
  # ActiveJob::Base by the engine. Enforcement happens at delivery time in the
  # Receiver, not at enqueue time.
  module ConcurrencyControls
    extend ActiveSupport::Concern

    included do
      class_attribute :concurrency_config, instance_accessor: false, default: nil
    end

    class_methods do
      def limits_concurrency(key:, to: 1, duration: nil, on_conflict: :block)
        unless %i[block discard].include?(on_conflict)
          raise ArgumentError, "on_conflict must be :block or :discard"
        end

        self.concurrency_config = {
          key: key,
          to: to,
          duration: duration,
          on_conflict: on_conflict
        }
      end

      def concurrency_limited?
        concurrency_config.present?
      end

      def concurrency_limit
        concurrency_config.fetch(:to)
      end

      def concurrency_on_conflict
        concurrency_config.fetch(:on_conflict)
      end

      def concurrency_duration
        concurrency_config[:duration] || SolidGcp.config.default_concurrency_duration
      end
    end

    # Resolves the semaphore key for this job instance.
    def concurrency_key
      raise SolidGcp::Error, "no concurrency limit declared" unless self.class.concurrency_limited?

      raw = self.class.concurrency_config.fetch(:key)
      value = raw.respond_to?(:call) ? instance_exec(*arguments, &raw) : raw
      Array(value).map { |part| stringify_concurrency_part(part) }.join("/")
    end

    private

    def stringify_concurrency_part(part)
      if part.respond_to?(:to_gid_param)
        part.to_gid_param
      elsif part.respond_to?(:to_global_id)
        part.to_global_id.to_param
      else
        part.to_s
      end
    end
  end
end
