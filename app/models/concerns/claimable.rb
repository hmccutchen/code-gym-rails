module Claimable
  extend ActiveSupport::Concern

  class_methods do
    def claim(name, column:, stale_after:)
      define_method(:"#{name}?") { claim_fresh?(column, stale_after) }
      define_method(:"claim_#{name}!") { |**conditions| take_claim(column, stale_after, conditions) }
      define_method(:"release_#{name}!") { |token| release_claim(column, token) }
    end
  end

  private

  def claim_fresh?(column, stale_after)
    self[column].present? && self[column] > stale_after.ago
  end

  def take_claim(column, stale_after, conditions)
    token = Time.current.floor(6)
    open = self.class.arel_table[column].eq(nil).or(self.class.arel_table[column].lt(stale_after.ago))
    taken = self.class.where(id: id, **conditions).where(open).update_all(column => token) == 1
    return nil unless taken

    write_claim(column, token)
    token
  end

  def release_claim(column, token)
    released = self.class.where(id: id, column => token).update_all(column => nil) == 1
    write_claim(column, nil) if released
  end

  def write_claim(column, value)
    self[column] = value
    clear_attribute_changes([ column ])
  end
end
