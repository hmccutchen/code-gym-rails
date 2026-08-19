# Whether this process is a Railway pull-request deployment.
#
# The variable is set by railway.toml's [environments.pr.deploy] block and
# nowhere else. That block is committed to the repo, reviewed in a PR, and
# applied ONLY to pull-request deployments — `pr` is a hardcoded key in
# Railway's config resolution order, not a name matched against an
# operator-typed environment. Production resolves its deploy config from
# [deploy], which sets nothing, so no scoping mistake in the Railway dashboard
# can turn this on the way a mis-scoped PREVIEW_SEED_EMAIL once could.
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
