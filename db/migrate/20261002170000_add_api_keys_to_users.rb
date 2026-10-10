# users.api_key stays for now: old code keeps serving while this pre-deploy migration runs.
class AddApiKeysToUsers < ActiveRecord::Migration[8.1]
  # Its own model, so this keeps working after User stops reading api_key; encryption ignores the class name.
  class LegacyUser < ActiveRecord::Base
    self.table_name = "users"
    encrypts :api_key
    serialize :api_keys, coder: JSON
    encrypts :api_keys
  end

  def up
    # text, like api_key: an encrypted payload outgrows short varchar limits.
    add_column :users, :api_keys, :text
    LegacyUser.reset_column_information

    LegacyUser.where.not(api_key: nil).find_each do |user|
      provider = user.provider.presence || AiProvider.detect(user.api_key)
      if provider
        user.update_columns(api_keys: { provider => user.api_key }, provider: provider)
      else
        Rails.logger.warn("AddApiKeysToUsers: unrecognized key format for user #{user.id}")
      end
    end
  end

  def down
    remove_column :users, :api_keys
  end
end
