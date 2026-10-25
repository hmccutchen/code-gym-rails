require "rails_helper"

RSpec.describe "Phone card pieces", type: :system do
  def inject(html)
    page.execute_script(%(document.querySelector("main .phone-page").insertAdjacentHTML("beforeend", #{%(<section class="card">#{html}</section>).to_json})))
  end

  before do
    resize(390)
    visit_as(create_fake_provider_user)
    visit account_path
  end

  it "gives a value row 52px and lets a long value wrap under its name" do
    inject(%(<div class="value-row"><label for="x">Time zone</label><span class="value-row-value" aria-hidden="true">#{'Mountain (Arizona, no DST) ' * 3}</span><select id="x"><option>a</option></select></div>))
    row = find(".value-row")
    expect(row.evaluate_script("this.getBoundingClientRect().height")).to be >= 52
    expect(row.evaluate_script("this.querySelector('select').getBoundingClientRect().height")).to eq(row.evaluate_script("this.getBoundingClientRect().height"))
    expect(row.evaluate_script("getComputedStyle(this.querySelector('select')).opacity")).to eq("0")
    expect(page_width).to eq(390)
  end

  it "draws a value row's divider as a border, which forced colors keep" do
    inject(%(<div class="value-row"><label for="x">Track</label><span class="value-row-value" aria-hidden="true">Senior</span><select id="x"><option>Senior</option></select></div>))
    style = page.evaluate_script("(s => [s.borderBottomWidth, s.boxShadow])(getComputedStyle(document.querySelector('.value-row')))")
    expect(style).to eq([ "1px", "none" ])
  end

  it "lets a tap on a value row's name or value reach its select" do
    inject(%(<div class="value-row"><label for="x">Track</label><span class="value-row-value" aria-hidden="true">Senior</span><select id="x"><option>Senior</option></select></div>))
    page.execute_script("document.querySelector('.value-row').scrollIntoView({ block: 'center' })")
    hits = page.evaluate_script(<<~JS)
      [".value-row", ".value-row > label", ".value-row-value"].map(selector => {
        const box = document.querySelector(selector).getBoundingClientRect();
        return document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2).tagName;
      })
    JS
    expect(hits).to eq(%w[SELECT SELECT SELECT])
  end

  it "spaces a card note under a value row, a segmented control or a text input" do
    inject(<<~HTML)
      <div class="value-row"><label for="x">Track</label><span class="value-row-value" aria-hidden="true">Senior</span><select id="x"><option>Senior</option></select></div><p class="card-note">after a row</p>
      <div class="segmented"><label class="segment"><input type="radio" name="n">2</label></div><p class="card-note">after segments</p>
      <input type="password" aria-label="Key"><p class="card-note">after an input</p>
    HTML
    gaps = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".phone-page > .card:last-child > .card-note"))
        .map(note => note.getBoundingClientRect().top - note.previousElementSibling.getBoundingClientRect().bottom)
    JS
    rem = page.evaluate_script("parseFloat(getComputedStyle(document.documentElement).fontSize)")
    expect(gaps.size).to eq(3)
    expect(gaps).to all(be >= (0.4 * rem) - 0.5)
  end

  it "adds no gap above a card note that follows a hidden input" do
    inject(%(<input type="hidden" name="authenticity_token" value="x"><p class="card-note">first line</p>))
    expect(find(".phone-page > .card:last-child > .card-note").evaluate_script("getComputedStyle(this).marginTop")).to eq("0px")
  end

  it "draws segments at least 44px tall on one row" do
    inject(%(<fieldset class="field-group"><legend>Daily sections</legend><div class="segmented">#{%w[Automatic 2 3 4].map { |t| %(<label class="segment"><input type="radio" name="n">#{t}</label>) }.join}</div></fieldset>))
    tops = page.evaluate_script("Array.from(document.querySelectorAll('.segment')).map(el => [el.getBoundingClientRect().height, Math.round(el.getBoundingClientRect().top)])")
    expect(tops.map(&:first)).to all(be >= 44)
    expect(tops.map(&:last).uniq.size).to eq(1)
  end

  it "mutes a disabled switch's row once" do
    inject(%(<label class="switch-row">Skip<input type="checkbox" class="switch" disabled></label>))
    muted = computed_color("--muted")
    row = find(".switch-row:has(.switch:disabled)")
    expect(row.evaluate_script("[getComputedStyle(this).opacity, getComputedStyle(this).color]")).to eq([ "1", muted ])
    expect(find(".switch:disabled").evaluate_script("getComputedStyle(this).opacity")).to eq("0.4")
  end

  it "gives a card's summary 48px" do
    page.execute_script(%(document.querySelector("main .phone-page").insertAdjacentHTML("beforeend", '<details class="card"><summary>Display</summary><p>x</p></details>')))
    expect(page.evaluate_script("document.querySelector('details.card > summary').getBoundingClientRect().height")).to be >= 48
  end

  it "lets an empty status line take no space, and spaces a filled one" do
    inject(%(<p class="card-note switch-status" role="status"></p>))
    status = find(".switch-status", visible: :all)
    expect(status.evaluate_script("[this.getBoundingClientRect().height, getComputedStyle(this).marginTop, getComputedStyle(this).marginBottom]")).to eq([ 0, "0px", "0px" ])
    status.execute_script("this.textContent = 'Saved'")
    expect(status.evaluate_script("getComputedStyle(this).marginTop")).to eq("4px")
  end

  it "puts a card tag beside its heading when it fits" do
    inject(%(<div class="card-heading"><h2>Connection</h2><span class="card-tag">Tap Save to apply</span></div>))
    tops = page.evaluate_script("['.card-heading h2', '.card-tag'].map(s => document.querySelector(s).getBoundingClientRect().top)")
    expect((tops[0] - tops[1]).abs).to be < 12
  end
end
