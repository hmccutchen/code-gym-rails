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

  it "names the draft store's key only through JavascriptReadyHelper" do
    key_shapes = [ /#{Regexp.escape(JavascriptReadyHelper::DRAFT_KEY)}/, /localStorage\.(?:get|set|remove)Item\(\s*["']/ ]
    offenders = offending_lines(Regexp.union(key_shapes))

    expect(offenders).to be_empty, <<~MESSAGE
      Draft key written out in a system spec: #{offenders.join(', ')}.
      Use draft_key_js, stored_draft_js, draft_absent_js, wait_for_draft_cleared
      or wait_for_answers_settled from JavascriptReadyHelper, which read the key
      from app/javascript/code_gym/draft_store.js (#501).
    MESSAGE
  end

  it "stubs one path's fetch, or a signed-out reply, only through FetchStubHelper" do
    stub_shapes = [ /\bdef (?:stub_fetch|fail_requests_to|drop_requests_to|redirect_requests_to_login|break_the_network|reply_to)\b/,
                    /window\.fetch = \(url, options\) => (?:url\.(?:endsWith|includes)\(|new URL\(url, location\.href\)\.pathname ===)/,
                    /window\.fetch = \(\) => Promise\.reject\(/, /["']redirected["']|\bredirected:\s*true\b/ ]
    offenders = offending_lines(Regexp.union(stub_shapes))

    expect(offenders).to be_empty, <<~MESSAGE
      Hand-built fetch stub in a system spec: #{offenders.join(', ')}.
      Use stub_fetch, fail_requests_to, drop_requests_to,
      redirect_requests_to_login or break_the_network from FetchStubHelper in
      spec/support/system_test_helper.rb (#514).
    MESSAGE
  end

  it "names the pull-refresh note's key only through JavascriptReadyHelper" do
    key_shapes = [ /#{Regexp.escape(JavascriptReadyHelper::PULL_NOTE_KEY)}/, /sessionStorage\.(?:get|set|remove)Item\(\s*["']codegym:/ ]
    offenders = offending_lines(Regexp.union(key_shapes))

    expect(offenders).to be_empty, <<~MESSAGE
      Pull-refresh note key written out in a system spec: #{offenders.join(', ')}.
      Use pull_note_key_js, pull_note_absent_js or leave_pull_note from
      JavascriptReadyHelper, which read the key from
      app/assets/javascripts/code_gym_bootstrap.js (#527).
    MESSAGE
  end

  describe JavascriptReadyHelper do
    it "reads the pull-refresh note key from code_gym_bootstrap.js" do
      source = JavascriptReadyHelper::BOOTSTRAP_PATH.read

      expect(source).to match(/^ *var PULL_NOTE = #{Regexp.escape(JavascriptReadyHelper::PULL_NOTE_KEY_JS)}$/)
      expect(described_class.pull_note_key_in(%(  var PULL_NOTE = "a-renamed-note"\n))).to eq("a-renamed-note")
      expect(described_class.pull_note_key_in(%(    var PULL_NOTE = "re-indented"\n))).to eq("re-indented")
      expect(JavascriptReadyHelper::PULL_NOTE_ABSENT).to eq("sessionStorage.getItem(#{JavascriptReadyHelper::PULL_NOTE_KEY_JS}) === null")
    end

    it "raises when code_gym_bootstrap.js no longer declares its note key the way the helper reads it" do
      [ "", %(  var PULL_NOTE = 'single-quoted'\n), %(  const PULL_NOTE = "renamed-binding"\n), %(  var PULL_REFRESH_NOTE = "renamed"\n) ].each do |source|
        expect { described_class.pull_note_key_in(source) }.to raise_error(RuntimeError, /Found no `var PULL_NOTE = "\.\.\."` line/)
      end
    end

    it "reads the draft key from draft_store.js" do
      source = JavascriptReadyHelper::DRAFT_STORE_PATH.read

      expect(source).to include(%(const KEY = #{JavascriptReadyHelper::DRAFT_KEY_JS}\n))
      expect(described_class.draft_key_in(%(const KEY = "a-key"\n))).to eq("a-key")
    end

    it "raises when draft_store.js no longer declares its key the way the helper reads it" do
      [ "", %(const KEY = 'single-quoted'\n), %(let KEY = "renamed-binding"\n), %(const DRAFT_KEY = "renamed"\n) ].each do |source|
        expect { described_class.draft_key_in(source) }.to raise_error(RuntimeError, /Found no `const KEY = "\.\.\."` line/)
      end
    end

    it "builds the settled wait from the draft-absent check and the save queue" do
      expect(JavascriptReadyHelper::ANSWERS_SETTLED)
        .to eq("#{JavascriptReadyHelper::DRAFT_ABSENT} && !window.CodeGymSaveStatus.pending()")
      expect(JavascriptReadyHelper::DRAFT_ABSENT).to eq("localStorage.getItem(#{JavascriptReadyHelper::DRAFT_KEY_JS}) === null")
    end
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
