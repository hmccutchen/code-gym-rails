# ActionController::RateLimiting captures its `store:` when the controller
# class is loaded, which would freeze whatever Rails.cache was at boot. This
# resolves it per call instead, so production gets Solid Cache and a spec can
# substitute a real store for the test env's :null_store.
#
# #increment is the only method the rate limiter calls.
class LazyCacheStore
  def increment(name, amount = 1, **options)
    Rails.cache.increment(name, amount, **options)
  end
end
