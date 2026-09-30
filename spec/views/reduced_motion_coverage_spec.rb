require "rails_helper"

# A new animation or transition should not quietly ignore the OS setting.
# Each CSS rule that declares motion needs a matching rule under
# prefers-reduced-motion that sets the same property to none for each of its
# selectors, and a script's motion option has to read the setting on its own
# line. spec/system/reduced_motion_spec.rb checks the rendered result.
RSpec.describe "reduced motion coverage" do
  MOTION = /\b(animation|transition)\s*:(?!\s*none\b)/
  REDUCED = "prefers-reduced-motion: reduce"

  def unhandled_motion(source)
    rules = ViewStyles.rules(source)
    reduced, normal = rules.partition { |rule| rule.media.any? { |media| media.include?(REDUCED) } }

    in_css = normal.flat_map do |rule|
      %w[animation transition].select { |property| rule.declaration(property).then { |value| value && value != "none" } }
        .flat_map { |property| rule.selectors.map { |selector| [ selector, property ] } }
    end.reject do |selector, property|
      reduced.any? { |rule| rule.selectors.include?(selector) && rule.declaration(property) == "none" }
    end.map { |selector, property| "#{selector} { #{property} }" }

    in_script = ViewStyles.outside_style_blocks(source).lines
      .select { |line| line.match?(MOTION) && !line.include?("prefers-reduced-motion") }
      .map(&:strip)

    in_css + in_script
  end

  it "flags one unhandled motion in a view that handles another" do
    source = <<~HTML
      <style>
        .spinner { animation: spin 1s infinite; }
        .panel { transition: opacity .2s; }
        @media (#{REDUCED}) { .spinner { animation: none; } }
      </style>
    HTML

    expect(unhandled_motion(source)).to eq([ ".panel { transition }" ])
  end

  it "flags a selector left out of a list the override only partly covers" do
    source = <<~HTML
      <style>
        .a, .b { transition: width .3s; }
        @media (#{REDUCED}) { .a { transition: none; } }
      </style>
    HTML

    expect(unhandled_motion(source)).to eq([ ".b { transition }" ])
  end

  it "flags a script's motion option that ignores the setting" do
    source = %(<script>Sortable.create(list, {\n  animation: 150,\n});</script>)

    expect(unhandled_motion(source)).to eq([ "animation: 150," ])
  end

  # A stylesheet is read as if it were one <style> block in a view.
  Rails.root.glob("{app/views/**/*.erb,app/assets/stylesheets/*.css}").each do |view|
    source = view.extname == ".css" ? "<style>#{view.read}</style>" : view.read
    next unless source.match?(MOTION)

    it "gives every motion in #{view.relative_path_from(Rails.root)} a reduced-motion rule" do
      expect(unhandled_motion(source)).to eq([])
    end
  end
end
