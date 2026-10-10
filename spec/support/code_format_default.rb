# Every example starts with CodeFormat handing code back unchanged.
#
# Formatting depends on what the machine has: RuboCop is always there, but
# Prettier needs Node and vendor/prettier's packages, which a contributor's
# checkout may lack. Unpinned, a canned provider snippet would be delivered
# differently on different machines, and every page snapshot that shows code
# would follow. A spec about formatting itself opts back in with
# `allow(CodeFormat).to receive(:all).and_call_original`; a later stub wins.
RSpec.configure do |config|
  config.before do
    allow(CodeFormat).to receive(:all) { |snippets, **| snippets }
  end
end
