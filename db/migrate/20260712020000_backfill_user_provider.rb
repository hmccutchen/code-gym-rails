# One-off: derives provider for users who saved a key under the old Anthropic-only validation.
class BackfillUserProvider < ActiveRecord::Migration[8.0]
  # Its own model, because User no longer reads the api_key column this migration ran against.
  class LegacyUser < ActiveRecord::Base
    self.table_name = "users"
    encrypts :api_key
  end

  def up
    LegacyUser.where.not(api_key: nil).find_each do |user|
      # Skip users who already have a provider set (idempotent)
      next if user.provider.present?

      begin
        key = user.api_key # decrypts transparently via `encrypts :api_key`
        provider =
          case key
          when /\Ask-ant-/ then "anthropic"
          when /\AAIza/    then "gemini"
          end

        if provider
          user.update_column(:provider, provider)
        else
          Rails.logger.warn("BackfillUserProvider: unrecognized key format for user #{user.id}")
        end
      rescue ActiveRecord::Encryption::Errors::Decryption => e
        Rails.logger.error("BackfillUserProvider: decryption failed for user #{user.id}: #{e.message}")
      end
    end
  end

  def down
    # Deliberately empty: removing the provider column, in its own migration, restores the prior state.
  end
end
