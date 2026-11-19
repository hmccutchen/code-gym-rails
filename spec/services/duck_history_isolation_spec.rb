require "rails_helper"

RSpec.describe "Duck history isolation" do
  it "lets only DuckAnswer read the labelled duck history" do
    own = %w[app/models/duck_thread.rb app/services/duck_answer.rb]
    files = Rails.root.glob("{app,lib}/**/*.{rb,erb}").map { |file| file.relative_path_from(Rails.root).to_s }

    readers = (files - own).select { |file| File.read(Rails.root.join(file)).include?("turns_for_duck") }
    expect(readers).to eq([])
  end
end
