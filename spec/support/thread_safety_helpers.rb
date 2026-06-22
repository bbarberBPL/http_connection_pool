# frozen_string_literal: true

# Helpers for the concurrency specs. Included into any example group tagged
# :thread_safety (wired up in spec_helper.rb).
module ThreadSafetyHelpers
  # A reusable barrier: all threads block on `await` until `count` threads have
  # arrived, then all are released simultaneously. Safer than a bare
  # ConditionVariable for precise race-condition testing.
  class CyclicBarrier
    def initialize(count)
      @count   = count
      @waiting = 0
      @mutex   = Mutex.new
      @cv      = ConditionVariable.new
    end

    def await
      @mutex.synchronize do
        @waiting += 1
        if @waiting >= @count
          @waiting = 0
          @cv.broadcast
        else
          @cv.wait(@mutex) until @waiting.zero?
        end
      end
    end
  end

  def cyclic_barrier(count)
    CyclicBarrier.new(count)
  end
end
