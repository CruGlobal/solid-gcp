# frozen_string_literal: true

require "test_helper"

class SemaphoreTest < SolidGcp::TestCase
  Semaphore = SolidGcp::Semaphore

  test "honors limit of 1" do
    assert Semaphore.wait("k", limit: 1, duration: 60)
    refute Semaphore.wait("k", limit: 1, duration: 60)
  end

  test "honors limit of N" do
    assert Semaphore.wait("k", limit: 3, duration: 60)
    assert Semaphore.wait("k", limit: 3, duration: 60)
    assert Semaphore.wait("k", limit: 3, duration: 60)
    refute Semaphore.wait("k", limit: 3, duration: 60)
  end

  test "signal frees a slot and caps at limit" do
    Semaphore.wait("k", limit: 1, duration: 60)
    refute Semaphore.wait("k", limit: 1, duration: 60)

    Semaphore.signal("k", limit: 1)
    assert Semaphore.wait("k", limit: 1, duration: 60)

    # signal beyond the limit does not overflow the counter
    Semaphore.signal("k", limit: 1)
    Semaphore.signal("k", limit: 1)
    assert_equal 1, Semaphore.find_by(key: "k").value
  end

  test "expiry sweep deletes stale leases" do
    Semaphore.wait("k", limit: 1, duration: 60)
    Semaphore.where(key: "k").update_all(expires_at: 1.hour.ago)

    assert_equal 1, Semaphore.expire_stale
    assert_equal 0, Semaphore.count
  end

  test "limit honored under threads" do
    limit = 3
    mutex = Mutex.new
    count = 0

    threads = 20.times.map do
      Thread.new do
        if Semaphore.wait("threaded", limit: limit, duration: 60)
          mutex.synchronize { count += 1 }
        end
      end
    end
    threads.each(&:join)

    assert_equal limit, count
  end
end
