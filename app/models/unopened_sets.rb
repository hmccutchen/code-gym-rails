module UnopenedSets
  PAUSE_AFTER = 3

  Entry = Data.define(:date, :opened, :saved)

  def self.pause?(sets, today:)
    latest = sets.max_by(PAUSE_AFTER, &:date)
    latest.size == PAUSE_AFTER && latest.all? { |set| unopened?(set, today: today) }
  end

  def self.unopened?(set, today:) = set.date < today && !set.opened && !set.saved
end
