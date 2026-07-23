# Demo content for a Railway PR app, whose database starts empty.
#
# railway.toml's preDeployCommand is shared with production, so this runs there
# too. Four rules make that safe: no variable means no action; rows are created
# only when absent and never updated or deleted; a non-blank attribute is never
# reassigned; and nothing outside the single named account is touched.
class PreviewSeed
  EMAIL_VAR     = "PREVIEW_SEED_EMAIL"
  DUMMY_API_KEY = "sk-ant-preview-not-a-real-key"

  def self.run! = new.run!

  def run!
    return nil if target_email.blank?

    user = find_or_create_user
    Time.use_zone(user.effective_time_zone) { seed_days(user) }
    seed_concept_reference
    user
  end

  private

  def target_email
    @target_email ||= ENV[EMAIL_VAR].to_s.strip.downcase
  end

  def find_or_create_user
    user = User.find_or_initialize_by(email: target_email)
    user.name        = "Preview Reviewer" if user.name.blank?
    user.skill_level = "solid"            if user.skill_level.blank?
    user.language    = "ruby_rails"       if user.language.blank?
    user.provider    = "anthropic"        if user.provider.blank?
    user.api_key     = DUMMY_API_KEY      if user.api_key.blank?
    user.save!
    user
  end

  def seed_days(user) = nil

  def seed_concept_reference = nil
end
