require "rails_helper"

RSpec.describe AuthenticatorSetupsHelper, type: :helper do
  it "renders the QR code as an inline svg with no XML declaration" do
    svg = helper.qr_code_svg("otpauth://totp/Coding%20Gym:dev%40example.com?secret=JBSWY3DPEHPK3PXP")

    expect(svg).to start_with("<svg")
    expect(svg).to include('class="qr-code"', 'role="img"', 'aria-label="QR code for adding Coding Gym')
  end

  it "groups the setup key in fours" do
    expect(helper.grouped_key("JBSWY3DPEHPK3PXPAB")).to eq("JBSW Y3DP EHPK 3PXP AB")
  end
end
