# frozen_string_literal: true

require "yaml"

module SolidGcp
  # Parses recurring.yml (Solid Queue's format) and enqueues entries by key.
  module Recurring
    module_function

    # Returns { key => entry_hash } for the current environment.
    def load(file: nil, env: nil)
      file ||= SolidGcp.config.recurring_file
      env ||= (defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.to_s : "development")
      return {} unless File.exist?(file)

      raw = YAML.load_file(file) || {}
      scoped = raw.key?(env) || raw.key?("shared") ? (raw[env] || raw["shared"] || {}) : raw
      (scoped || {}).transform_keys(&:to_s)
    end

    def entry(key, **opts)
      load(**opts)[key.to_s]
    end

    # Converts an entry's schedule to a cron string via fugit; raises for
    # non-cron schedules (e.g. "every 2 seconds") that Cloud Scheduler can't take.
    def cron_for(entry)
      require "fugit"
      schedule = entry.fetch("schedule")
      parsed = Fugit.parse(schedule)
      unless parsed.respond_to?(:to_cron_s)
        raise ConfigurationError, "recurring schedule #{schedule.inspect} is not cron-expressible"
      end

      cron = parsed.to_cron_s
      # Cloud Scheduler is minute-granular; reject sub-minute (6-field) crons.
      if cron.split(/\s+/).size > 5
        raise ConfigurationError,
          "recurring schedule #{schedule.inspect} is sub-minute; Cloud Scheduler is minute-granular"
      end

      cron
    end

    # Enqueues the entry's job (or RecurringCommandJob for command: entries).
    # Returns false for an unknown key.
    def enqueue(key, **opts)
      e = entry(key, **opts)
      return false unless e

      job_class, args = resolve(e)
      configured = e["queue"] ? job_class.set(queue: e["queue"]) : job_class
      configured.perform_later(*args)
      true
    end

    def resolve(entry)
      if entry["command"]
        [RecurringCommandJob, [entry["command"]]]
      else
        [entry.fetch("class").constantize, normalize_args(entry["args"])]
      end
    end

    def normalize_args(args)
      case args
      when nil   then []
      when Array then args
      else            [args]
      end
    end
  end
end
