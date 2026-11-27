require "rails_helper"

RSpec.describe "Setup exercise recommendations", type: :request do
  let(:user) { create_user_with_key }

  def page_html = Nokogiri::HTML(response.body)

  def name(key) = I18n.t("sections.#{key}.name")

  [ nil, 2 ].each do |count|
    it "names the regular sections without promising every-set delivery at #{count || "Automatic"}" do
      user.update!(daily_section_count: count)
      login_as(user)

      get setup_path

      expect(page_html.at_css("#exercise-mix .mix-group > legend").text).to eq("Your regular sections")
    end
  end

  it "shows the regular preferences without turning historical extras into guaranteed exercises" do
    user.update!(daily_section_count: 3, daily_section_kinds: %w[code_review design_comparison challenge])
    login_as(user)

    get setup_path

    expect(page_html.css("#exercise-mix .mix-group").first.css("span[id^=mix-name-]").map(&:text))
      .to eq([ name("code_review"), name("design_comparison") ])
    expect(page_html.at_css("#weight-challenge")).to be_present
    expect(user.reload.daily_section_kinds).to eq(%w[code_review design_comparison challenge])
  end

  def rotating_legends = page_html.css("#exercise-mix .mix-group-rotating > legend").map(&:text)

  def kinds_named(kinds) = kinds.map { |kind| name(kind.key) }.to_sentence(two_words_connector: " or ", last_word_connector: ", or ")

  it "names each rotating group by the kinds it holds, never by a position in the day" do
    login_as(user)

    get setup_path

    slots = ExerciseSection.optional_slots(daily: DailyKinds.for(user)).select { |_, kinds| kinds.size > 1 }
    expect(rotating_legends).to eq(slots.map { |_, kinds| I18n.t("exercise_mix.rotating_group", kinds: kinds_named(kinds)) })
    expect(rotating_legends.join).not_to match(/third|fourth/i)
  end

  it "offers a historical extra alongside the other eligible kinds" do
    user.update!(daily_section_count: 3, daily_section_kinds: %w[code_review design_comparison architecture])
    login_as(user)

    get setup_path

    expect(rotating_legends.join).to include(name("architecture"))
    expect(rotating_legends).to include(a_string_including(name("challenge"), name("security_review")))
  end

  it "names other eligible kinds without a count warning" do
    login_as(user)

    get setup_path

    expect(page_html.css("#exercise-mix .mix-group > legend").map(&:text)).to include(I18n.t("exercise_mix.single_group", kind: name("pattern")))
    expect(page_html.at_css("#exercise-mix .mix-unplaced-note")).to be_nil
  end
end
