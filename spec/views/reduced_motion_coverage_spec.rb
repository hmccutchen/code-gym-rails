require "rails_helper"

# A new animation or transition should not quietly ignore the OS setting.
# Every view that declares motion must also say what it does under
# prefers-reduced-motion; spec/system/reduced_motion_spec.rb checks the result.
RSpec.describe "reduced motion coverage" do
  MOTION = /\b(animation|transition)\s*:\s*(?!none\b)/

  Rails.root.glob("app/views/**/*.erb").each do |view|
    source = view.read
    next unless source.match?(MOTION)

    it "gives #{view.relative_path_from(Rails.root)} a reduced-motion rule" do
      expect(source).to include("prefers-reduced-motion")
    end
  end
end
