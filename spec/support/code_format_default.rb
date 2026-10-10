# Prettier's presence varies by machine; a formatting spec opts back in with and_call_original.
RSpec.configure do |config|
  config.before do
    allow(CodeFormat).to receive(:all) { |snippets, **| snippets }
  end
end
