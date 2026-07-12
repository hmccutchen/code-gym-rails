# One-off data migration: existing users already saved an encrypted API key
# under the old Anthropic-only validation, but we derive `provider` the same
# way ApiKeysController does going forward, in case any non-Anthropic-shaped
# key ever slipped through.
class BackfillUserProvider < ActiveRecord::Migration[8.0]
  def up
    User.where.not(api_key: nil).find_each do |user|
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
    end
  end

  def down
    # no-op — reverting the provider column (added in a separate migration)
    # is sufficient; there's no prior state to restore.
  end
end
