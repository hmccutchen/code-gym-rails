namespace :preview do
  desc "Seed demo content for a Railway PR app (no-op unless PREVIEW_SEED_EMAIL is set)"
  task seed: :environment do
    user = PreviewSeed.run!
    puts user ? "Preview seed complete for #{user.email}" : "Preview seed skipped: PREVIEW_SEED_EMAIL is not set"
  end
end
