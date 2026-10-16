# Reads and writes users.learning_track, which User ignores until the next release drops the column.
module LegacyLearningTrack
  def write_learning_track(user, value)
    ActiveRecord::Base.connection.exec_update(
      "UPDATE users SET learning_track = #{ActiveRecord::Base.connection.quote(value)} WHERE id = #{user.id}"
    )
  end

  def read_learning_track(user)
    ActiveRecord::Base.connection.select_value("SELECT learning_track FROM users WHERE id = #{user.id}")
  end
end

RSpec.configure { |config| config.include LegacyLearningTrack }
