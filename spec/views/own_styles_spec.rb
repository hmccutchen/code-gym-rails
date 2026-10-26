require "rails_helper"

RSpec.describe "Page sheets' own styles" do
  def foreign_classes(source)
    carried = ViewStyles.markup_classes(source)
    ViewStyles.selected_classes(ViewStyles.rules(source)).reject { |name| carried.include?(name) }
  end

  it "sees a class selected inside an at-rule" do
    source = %(<style>.own { color: red; } @media (max-width: 600px) { .foreign { color: blue; } }</style><p class="own"></p>)

    expect(foreign_classes(source)).to eq([ "foreign" ])
  end

  it "doesn't take a name in an id, text, Ruby code or another attribute as a class" do
    source = <<~ERB
      <style>.email, .total, .hint, .note { color: red; }</style>
      <span id="email" data-kind="total" aria-label="hint"><%= current_user.email %> note</span>
    ERB

    expect(foreign_classes(source)).to eq(%w[email total hint note])
  end

  it "reads quoted class attributes, including a class an ERB string adds" do
    source = <<~ERB
      <style>.one, .two, .three, .four { color: red; }</style>
      <p class="one two"></p><p class='three'></p>
      <fieldset class="one<%= " four" if suggested %>"></fieldset>
    ERB

    expect(foreign_classes(source)).to be_empty
  end

  it "reads class literals passed to helpers, including a nested form class" do
    source = <<~ERB
      <style>.btn, .btn-sm, .mix-ladders, .switch, .solo { color: red; }</style>
      <%= button_to "Go", root_path, class: "btn btn-sm", form: { class: "mix-ladders" } %>
      <%= form.check_box :nudges, { class: 'switch' } %>
      <%= tag.div class: "solo" do %><% end %>
    ERB

    expect(foreign_classes(source)).to be_empty
  end

  it "reads only the static pieces of a class name built from Ruby" do
    source = <<~ERB
      <style>.slot-1, .slot, .tag-a { color: red; }</style>
      <p class="slot-<%= n %>"></p><%= tag.p class: "tag-\#{kind} slot" %>
    ERB

    expect(foreign_classes(source)).to eq(%w[slot-1 tag-a])
  end

  it "treats a class named only inside :not() as left alone, not styled" do
    source = %(<style>.field label:not(:where(.switch-row)) { display: block; } .field :not(.gone) .kept { color: red; }</style><div class="field"></div>)

    expect(foreign_classes(source)).to eq([ "kept" ])
  end

  { "account" => "accounts", "settings" => "api_keys", "today" => "{dashboard,responses}" }.each do |page, folder|
    it "keeps pages/#{page}.css to classes the #{folder} views carry" do
      markup = Dir[Rails.root.join("app/views/#{folder}/**/*.erb")].sort.map { |path| File.read(path) }.join("\n")
      carried = ViewStyles.markup_classes(markup) + ExerciseSection.all.flat_map { |kind| kind.answer_class.split }
      rules = ViewStyles.stylesheet_rules(Rails.root.join("app/assets/stylesheets/pages/#{page}.css"))
      foreign = ViewStyles.selected_classes(rules).reject { |name| carried.include?(name) }

      expect(foreign).to be_empty, "pages/#{page}.css styles #{foreign.join(', ')}, which no #{folder} view uses. Move each rule to the sheet of the page that renders that class."
    end
  end
end
