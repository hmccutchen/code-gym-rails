RSpec.shared_examples "a provider reading a reply leaf of any shape" do |count_paths:, other_paths:, required_paths:|
  include AuthHelpers

  let(:user) { create_user_with_key }

  def logged_leaf_reply(path, value)
    body = valid_reply.deep_dup
    parent = path.size > 1 ? body.dig(*path[0...-1]) : body
    value == :absent ? parent.delete(path.last) : parent[path.last] = value
    service.instance_variable_set(:@conn, stubbed_connection([ [ 200, body.to_json ] ]))
    request = AiService::Request.build(purpose: "duck_thread", system: "sys", prompt: "p", single_attempt: true)
    service.send(:call_and_log, user, request)
  end

  before do
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
  end

  count_paths.product([ { "n" => 5 }, [ 5 ], "5", 5, -1 ]).each do |path, value|
    it "records one usage row and #{value == 5 ? 'keeps' : 'marks unknown'} the token counts when #{path.join('.')} is #{value.inspect}" do
      result = nil
      expect { result = logged_leaf_reply(path, value) }.to change(ApiUsage, :count).by(1)
      expect(result.fetch(:tokens_unknown, false)).to eq(value != 5)
    end
  end

  other_paths.product([ { "n" => 5 }, [ 5 ], "5", 5 ]).each do |path, value|
    it "records one usage row without raising when #{path.join('.')} is #{value.inspect}" do
      expect { logged_leaf_reply(path, value) }.to change(ApiUsage, :count).by(1)
    end
  end

  required_paths.product([ :absent, nil ]).each do |path, value|
    it "records one usage row, marks the token counts unknown and warns when the required #{path.join('.')} is #{value == :absent ? 'absent' : 'null'}" do
      result = nil
      expect { result = logged_leaf_reply(path, value) }.to change(ApiUsage, :count).by(1)
      expect(result).to include(tokens_unknown: true)
      expect(Rails.logger).to have_received(:warn).with(a_string_including("[usage]", described_class.name, "#{path.last} is missing")).once
    end
  end

  (count_paths - required_paths).product([ :absent, nil ]).each do |path, value|
    it "keeps the token counts known and warns nothing when the optional #{path.join('.')} is #{value == :absent ? 'absent' : 'null'}" do
      expect(logged_leaf_reply(path, value)).not_to have_key(:tokens_unknown)
      expect(Rails.logger).not_to have_received(:warn)
    end
  end

  it "warns once with the provider and the field, never the value, when a count is malformed" do
    path = count_paths.first
    logged_leaf_reply(path, "leaked-value-77")

    expect(Rails.logger).to have_received(:warn)
      .with(a_string_including("[usage]", described_class.name, path.last).and(satisfy { |line| !line.include?("leaked-value-77") })).once
  end

  it "keeps the token counts known and warns nothing when the counts are well formed" do
    expect(logged_leaf_reply(count_paths.first, 5)).not_to have_key(:tokens_unknown)
    expect(Rails.logger).not_to have_received(:warn)
  end
end
