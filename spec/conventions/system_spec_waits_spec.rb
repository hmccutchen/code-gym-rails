require "rails_helper"

RSpec.describe "Conventions held over system spec waits" do
  def system_files = Dir[Rails.root.join("spec/system/**/*.rb")].sort

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  def offending_lines(pattern, except: [])
    (system_files - except.map { |path| Rails.root.join(path).to_s }).flat_map do |path|
      File.readlines(path).filter_map.with_index(1) do |line, number|
        "#{relative(path)}:#{number}" if line.match?(pattern)
      end
    end
  end

  it "waits through Capybara or wait_for, never a hand-written poll loop" do
    loop_shapes = [ /\bTimeout\.timeout\b/, /^[^#]*\bsleep\b[^#]*\b(?:until|while)\b/, /\.times\s*\{[^}]*\bsleep\b/,
                    /\bdef wait_(?:for|until)\b/, /\bCLOCK_MONOTONIC\b/ ]
    offenders = offending_lines(Regexp.union(loop_shapes))

    expect(offenders).to be_empty, <<~MESSAGE
      Hand-written wait in a system spec: #{offenders.join(', ')}.
      Use wait_for from spec/support/system_test_helper.rb. It raises on
      timeout and follows Capybara.default_max_wait_time (#456).
    MESSAGE
  end

  it "passes no wait: or timeout: longer than a deliberate short negative check" do
    limits = [ /\bwait: (?:[3-9]|\d{2,})\b/, /\bsynchronize\(\d/, /\bwait_for_js_condition\b.*\btimeout:/ ]
    offenders = offending_lines(Regexp.union(limits), except: [ "spec/system/wait_for_js_condition_spec.rb" ])

    expect(offenders).to be_empty, <<~MESSAGE
      Explicit Capybara wait in a system spec: #{offenders.join(', ')}.
      Every wait follows Capybara.default_max_wait_time, so a slow run has
      one limit to raise (#456).
    MESSAGE
  end

  describe PollingHelper do
    let(:waiter) { Object.new.extend(described_class) }

    it "returns the block's value once it holds" do
      answers = [ nil, false, "saved" ]

      expect(waiter.wait_for(1) { answers.shift }).to eq("saved")
    end

    it "raises on timeout instead of returning silently" do
      expect { waiter.wait_for(0.1) { false } }.to raise_error(RuntimeError, /Waited 0.1s at .+ and the condition never held/)
    end

    it "times out on the monotonic clock, so a frozen travel_to clock can't hold it forever" do
      travel_to(Time.current) do
        expect { waiter.wait_for(0.1) { false } }.to raise_error(RuntimeError)
      end
    end
  end
end
