# frozen_string_literal: true

# Helpers for the fiber/async specs. Included into any example group tagged
# :fiber (wired up in spec_helper.rb).
#
# created_pools tracks every Pool built via make_pool so the example group can
# close them all in one after hook — a raising example or Async block can then
# never leak a pool.
module FiberHelpers
  def created_pools
    @created_pools ||= []
  end

  def make_pool(origin, size)
    pool = HttpConnectionPool::Pool.new(origin: origin, size: size, timeout: 3.0)
    created_pools << pool
    pool
  end

  def close_created_pools
    created_pools.each(&:close)
  end
end
