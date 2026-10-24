require "rails_helper"

RSpec.describe SignInCompletion do
  include AuthHelpers

  let(:host) do
    Class.new do
      include SignInCompletion
      public :complete_sign_in

      def session = @session ||= {}
    end.new
  end
  let(:user) { create_user_with_key }

  it "refuses to finish an authenticator account's sign-in on the emailed code" do
    enroll_second_factor(user)

    expect { host.complete_sign_in(user, checked_at: Time.current, factor: :emailed_code) }
      .to raise_error(SignInCompletion::WrongFactor)
    expect(host.session[:user_id]).to be_nil
  end

  it "refuses an unknown factor" do
    expect { host.complete_sign_in(user, checked_at: Time.current, factor: :password) }
      .to raise_error(SignInCompletion::WrongFactor)
  end
end
