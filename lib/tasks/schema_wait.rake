namespace :db do
  desc "Block until the schema the Solid Queue worker needs exists (Railway worker pre-deploy)"
  task wait_for_schema: :environment do
    SchemaWait.call
    puts "Schema ready"
  end
end
