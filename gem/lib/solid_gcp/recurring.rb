# frozen_string_literal: true

require "yaml"

module SolidGcp
  # Parses recurring.yml (Solid Queue's format) and enqueues entries by key.
  module Recurring
    module_function

    # Returns { key => entry_hash } for the current environment.
    #
    # Accepts either shape: a flat map of entries, or Solid Queue's env-scoped
    # file (a section per env, or a "shared" section). Aliases are enabled because
    # the env-scoped form is idiomatically written with a `default: &default`
    # anchor merged into each env — Psych refuses those by default, so a file
    # copied straight off a Solid Queue app used to raise
    # Psych::AliasesNotEnabled.
    def load(file: nil, env: nil)
      file ||= SolidGcp.config.recurring_file
      env ||= (defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.to_s : "development")
      return {} unless File.exist?(file)

      raw = YAML.load_file(file, aliases: true) || {}
      (scope(raw, file: file, env: env) || {}).transform_keys(&:to_s)
    end

    # Picks the entries out of a parsed recurring file.
    def scope(raw, file:, env:)
      return raw[env] if raw.key?(env)
      return raw["shared"] if raw.key?("shared")
      return raw unless env_scoped?(raw)

      # The file is scoped by env and has no section for this one. Falling back to
      # the whole file would make every env name a job key, which reads as a
      # working config: `scheduler:sync` would create Cloud Scheduler jobs named
      # solid-gcp-production and friends. Say what's wrong instead.
      raise ConfigurationError,
        "#{file} has no recurring entries for env #{env.inspect} " \
        "(sections: #{raw.keys.sort.join(', ')}). Add a #{env.inspect} or \"shared\" section."
    end

    # True when every top-level value holds entries rather than being one — i.e.
    # the file is scoped by environment. An empty (nil) section still counts, so
    # `development:` with nothing under it doesn't make the file look flat.
    def env_scoped?(raw)
      return false unless raw.is_a?(Hash) && raw.any?

      raw.each_value.all? { |value| value.nil? || (value.is_a?(Hash) && !entry?(value)) }
    end

    def entry?(value)
      value.key?("schedule") || value.key?("class") || value.key?("command")
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
