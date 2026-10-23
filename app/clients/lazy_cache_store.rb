# rate_limit binds store: at class load; resolving Rails.cache per call lets specs swap in a real store.
class LazyCacheStore
  def increment(name, amount = 1, **options)
    Rails.cache.increment(name, amount, **options)
  end
end
