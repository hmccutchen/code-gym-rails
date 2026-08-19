namespace :preview do
  desc "Seed demo content for a Railway PR app (no-op outside a pull-request deployment)"
  task seed: :environment do
    user = PreviewSeed.run!
    puts user ? "Preview seed complete for #{user.email}" : "Preview seed skipped: not a preview app"
  end
end
