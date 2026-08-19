# Whether the PREVIEW_APP environment variable is set.
#
# In a deployed environment, the only thing that sets it is railway.toml's
# [environments.pr.deploy] block — committed to the repo, reviewed in a PR,
# and applied ONLY to pull-request deployments, since `pr` is a hardcoded key
# in Railway's config resolution order, not a name matched against an
# operator-typed environment. Production resolves its deploy config from
# [deploy], which sets nothing, so no accidental scoping mistake in the
# Railway dashboard can turn this on the way a mis-scoped PREVIEW_SEED_EMAIL
# once could — though, like that variable, PREVIEW_APP is still an ordinary
# env var nothing stops someone from setting by hand. (It's also reachable
# locally on purpose: `PREVIEW_APP=1 bin/dev` is a documented way to exercise
# this outside Railway entirely.)
#
# One authority rather than three ENV checks: PreviewSeed, PreviewMail, and
# PreviewAutoLogin all derive from this, so "is this a preview app" has exactly
# one definition to change.
module PreviewEnvironment
  VAR = "PREVIEW_APP".freeze

  def self.active?
    ENV[VAR].to_s.strip.present?
  end
end
