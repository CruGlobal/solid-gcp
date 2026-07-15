# frozen_string_literal: true

module SolidGcp
  # Dev stand-in for Cloud Scheduler: in :local mode a server process ticks the
  # current env's recurring.yml entries in-process through the same enqueue path
  # (Recurring.enqueue) that /recurring/:key uses.
  module LocalRecurring
    @threads = []
    @started = false
    @mutex = Mutex.new

    module_function

    def started?
      @started
    end

    # Idempotent: no-op if already started. Spawns one ticking thread per
    # cron-expressible entry for the current env.
    def start
      @mutex.synchronize do
        return if @started

        require "fugit"
        keys = []
        Recurring.load.each do |key, entry|
          cron = parse_cron(key, entry) or next
          @threads << spawn_thread(key, cron)
          keys << key
        end
        @started = true
        log_info("[solid_gcp] local recurring: ticking #{keys.size} " \
                 "entries (#{keys.join(', ')})")
      end
    end

    # Test hook + symmetry: kill all ticking threads and reset started state.
    def stop
      @mutex.synchronize do
        @threads.each { |thread| thread.kill }
        @threads = []
        @started = false
      end
    end

    # Returns a fugit cron for the entry, or nil (with a warn) when the schedule
    # isn't cron-expressible. No minute-granularity restriction locally — unlike
    # scheduler:sync, sub-minute crons may tick (leniency eases dev/testing).
    def parse_cron(key, entry)
      parsed = Fugit.parse(entry.fetch("schedule"))
      return parsed if parsed.respond_to?(:next_time)

      log_warn("[solid_gcp] recurring '#{key}': schedule not cron-expressible, " \
               "skipping locally")
      nil
    end

    # One daemon-ish thread per entry: recompute next_time each iteration (from
    # Time.now) so drift doesn't accumulate, then enqueue. A bad firing logs and
    # loops; it must not kill the ticker.
    def spawn_thread(key, cron)
      Thread.new do
        loop do
          next_at = cron.next_time(Time.now)
          sleep([next_at.to_t - Time.now, 0].max)
          begin
            # Recurring.enqueue re-reads the yml per firing (cheap; picks up arg
            # edits — schedule changes still need a server restart).
            wrap { Recurring.enqueue(key) }
          rescue StandardError => e
            log_error("[solid_gcp] recurring '#{key}': #{e.class}: #{e.message}")
          end
        end
      end
    end

    def wrap(&block)
      if defined?(Rails) && Rails.application
        Rails.application.executor.wrap(&block)
      else
        yield
      end
    end

    def log_info(message)
      logger ? logger.info(message) : Kernel.warn(message)
    end

    def log_warn(message)
      logger ? logger.warn(message) : Kernel.warn(message)
    end

    def log_error(message)
      logger ? logger.error(message) : Kernel.warn(message)
    end

    def logger
      Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
    end
  end
end
