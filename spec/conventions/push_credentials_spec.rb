require "rails_helper"

RSpec.describe "with_push_credentials and without_push_credentials", type: :request do
  around do |example|
    original = ENV.slice(WebPushCredentials::PUBLIC_KEY_VAR, WebPushCredentials::PRIVATE_KEY_VAR)
    example.run
  ensure
    [ WebPushCredentials::PUBLIC_KEY_VAR, WebPushCredentials::PRIVATE_KEY_VAR ].each { |name| ENV.delete(name) }
    ENV.update(original)
  end

  it "configures web push inside the block" do
    ENV.delete(WebPushCredentials::PUBLIC_KEY_VAR)
    ENV.delete(WebPushCredentials::PRIVATE_KEY_VAR)

    with_push_credentials do
      expect(WebPushCredentials).to be_configured
      expect(WebPushCredentials.public_key).to eq(PushCredentials::PUBLIC_KEY)
    end
  end

  it "leaves absent variables absent afterward" do
    ENV.delete(WebPushCredentials::PUBLIC_KEY_VAR)
    ENV.delete(WebPushCredentials::PRIVATE_KEY_VAR)

    with_push_credentials { nil }

    expect(ENV).not_to have_key(WebPushCredentials::PUBLIC_KEY_VAR)
    expect(ENV).not_to have_key(WebPushCredentials::PRIVATE_KEY_VAR)
  end

  it "restores the values set before it, even when the block raises" do
    ENV[WebPushCredentials::PUBLIC_KEY_VAR] = "earlier-public"
    ENV[WebPushCredentials::PRIVATE_KEY_VAR] = "earlier-private"

    expect { with_push_credentials { raise "boom" } }.to raise_error("boom")

    expect(ENV[WebPushCredentials::PUBLIC_KEY_VAR]).to eq("earlier-public")
    expect(ENV[WebPushCredentials::PRIVATE_KEY_VAR]).to eq("earlier-private")
  end

  it "leaves web push unconfigured inside without_push_credentials, whatever was set before" do
    ENV[WebPushCredentials::PUBLIC_KEY_VAR] = "earlier-public"
    ENV[WebPushCredentials::PRIVATE_KEY_VAR] = "earlier-private"

    without_push_credentials do
      expect(WebPushCredentials).not_to be_configured
      expect(ENV).not_to have_key(WebPushCredentials::PUBLIC_KEY_VAR)
      expect(ENV).not_to have_key(WebPushCredentials::PRIVATE_KEY_VAR)
    end
  end

  it "restores the values without_push_credentials removed, even when the block raises" do
    ENV[WebPushCredentials::PUBLIC_KEY_VAR] = "earlier-public"
    ENV[WebPushCredentials::PRIVATE_KEY_VAR] = "earlier-private"

    expect do
      without_push_credentials do
        expect(WebPushCredentials).not_to be_configured
        raise "boom"
      end
    end.to raise_error("boom")

    expect(ENV[WebPushCredentials::PUBLIC_KEY_VAR]).to eq("earlier-public")
    expect(ENV[WebPushCredentials::PRIVATE_KEY_VAR]).to eq("earlier-private")
  end

  it "restores a half-set keypair after without_push_credentials, leaving the absent half absent" do
    ENV[WebPushCredentials::PUBLIC_KEY_VAR] = "earlier-public"
    ENV.delete(WebPushCredentials::PRIVATE_KEY_VAR)

    without_push_credentials { expect(ENV).not_to have_key(WebPushCredentials::PUBLIC_KEY_VAR) }

    expect(ENV[WebPushCredentials::PUBLIC_KEY_VAR]).to eq("earlier-public")
    expect(ENV).not_to have_key(WebPushCredentials::PRIVATE_KEY_VAR)
  end

  it "is no longer defined beside the browser stubs" do
    expect(PushApiStubs.instance_methods).not_to include(:with_push_credentials)
  end
end

RSpec.describe "the push credential helpers in a job spec", type: :job do
  it "is available" do
    expect(self).to respond_to(:with_push_credentials)
    expect(self).to respond_to(:without_push_credentials)
  end
end
