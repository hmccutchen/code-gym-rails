# The files the isolation specs scan: everything below the controllers and views, so a new model is scanned unless a spec names it an owner.
module IsolationScope
  def isolation_scope
    Rails.root.glob("app/{models,services,jobs,prompts,clients}/**/*.rb").map { |file| file.relative_path_from(Rails.root).to_s }
  end
end

RSpec.configure { |config| config.include IsolationScope }
