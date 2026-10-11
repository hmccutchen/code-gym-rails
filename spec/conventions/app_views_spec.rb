require "rails_helper"

RSpec.describe "Conventions held over app/views" do
  def view_files = Dir[Rails.root.join("app/views/**/*.erb")].sort

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  it "keeps every page script in a Stimulus controller rather than an inline tag" do
    offenders = view_files.flat_map do |path|
      File.readlines(path).filter_map.with_index(1) do |line, number|
        "#{relative(path)}:#{number}" if line.match?(/<script\b/i)
      end
    end

    expect(offenders).to be_empty, <<~MESSAGE
      Inline <script> in a view: #{offenders.join(', ')}.
      The content security policy allows a script only from this origin or a
      nonce the importmap tags carry, so an inline tag never runs. Put the
      behaviour in app/javascript/controllers and bind it with data-action.
    MESSAGE
  end
end
