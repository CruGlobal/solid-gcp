# frozen_string_literal: true

# Shared job fixtures for the test suite.

RAN = Hash.new(0)

class PlainJob < ActiveJob::Base
  def perform(*args)
    RAN[:plain] += 1
  end
end

class RecordingJob < ActiveJob::Base
  def perform(value)
    RAN[value] += 1
  end
end

class BoomError < StandardError; end

class RetryingJob < ActiveJob::Base
  retry_on BoomError, wait: :polynomially_longer, attempts: 5

  def perform
    raise BoomError, "boom"
  end
end

class DiscardingJob < ActiveJob::Base
  discard_on BoomError

  def perform
    raise BoomError, "discard me"
  end
end

class UnhandledJob < ActiveJob::Base
  def perform
    raise "unhandled failure"
  end
end

class InfraJob < ActiveJob::Base
  def perform
    raise ActiveRecord::ConnectionNotEstablished, "db waking"
  end
end

class DiscardSingletonJob < ActiveJob::Base
  limits_concurrency key: "singleton", to: 1, on_conflict: :discard

  def perform
    RAN[:singleton] += 1
  end
end

class BlockingPerUserJob < ActiveJob::Base
  limits_concurrency key: ->(user_id) { "user/#{user_id}" }, to: 1, on_conflict: :block

  def perform(user_id)
    RAN[:blocking] += 1
  end
end

class LongImportJob < ActiveJob::Base
  perform_via :cloud_run_job, job: "import-runner"

  def perform(*)
  end
end
