require "rails_helper"

RSpec.describe PracticeSchedule::Assignments do
  let(:kinds) { [ ExerciseSection::CodeReview, ExerciseSection::Pattern ] }
  let(:hosts) { DayHosts.new("ruby_rails", mode: :application_code) }
  let(:request) do
    { kind: "pattern", concept: "memoization", bucket: "ruby_rails", mode: "normal_retry",
      source_response_id: 1, requested_at: "2026-11-06T12:00:00.123456Z" }
  end

  it "places a constrained retry beside flexible maintenance rather than losing either" do
    assignments, = described_class.plan(kinds: kinds, hosts: hosts, pending: [ request ], reinforcement: [],
      due: [ { concept: "n_plus_one", bucket: "ruby_rails", overdue_ratio: 1 } ], drills: [], service: {}, sequence: 1)
    expect(assignments["pattern"]).to include(reason: "normal_retry", concept: "memoization")
    expect(assignments["code_review"]).to include(reason: "retention", concept: "n_plus_one")
  end

  it "gives persistent requests and both maintenance classes bounded contested opportunities" do
    requests = [ request, request.merge(concept: "n_plus_one", mode: "simplified") ]
    service = {}
    seen = Hash.new { |hash, key| hash[key] = [] }
    24.times do |index|
      assignments, service = described_class.plan(kinds: [ ExerciseSection::Pattern ], hosts: hosts,
        pending: requests, reinforcement: [], due: [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 1 } ],
        drills: [ { concept: "n_plus_one", bucket: "ruby_rails" } ], service: service, sequence: index + 1)
      entry = assignments.fetch("pattern")
      key = entry[:reason].in?(%w[retention drill]) ? entry[:reason] : entry[:concept]
      seen[key] << index + 1
    end

    it "does not let maintenance of one concept starve that concept's simplified practice" do
      requests = [ request.merge(mode: "simplified"), request.merge(concept: "n_plus_one") ]
      service = {}
      practice = 12.times.filter_map do |index|
        assigned, service = described_class.plan(kinds: [ ExerciseSection::Pattern ], hosts: hosts, pending: requests,
          reinforcement: [], due: [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 1 } ],
          drills: [], service: service, sequence: index + 1)
        entry = assigned.fetch("pattern")
        entry[:concept] unless entry[:reason] == "retention"
      end

      it "places maintenance on a spare host before letting ordinary reinforcement displace a pending request" do
        assignments, = described_class.plan(kinds: kinds, hosts: hosts, pending: [ request ],
          reinforcement: [ { concept: "service_objects", bucket: "ruby_rails", tier: "standard" } ],
          due: [ { concept: "n_plus_one", bucket: "ruby_rails", overdue_ratio: 1 } ], drills: [],
          service: { "pattern" => { "last_lane" => "practice", "last_maintenance" => nil, "concepts" => [] } }, sequence: 2)
        expect(assignments["pattern"]).to include(reason: "normal_retry", concept: "memoization")
        expect(assignments["code_review"]).to include(reason: "retention", concept: "n_plus_one")
      end
      expect(practice.each_slice(2).to_a).to all(match_array(%w[memoization n_plus_one]))
    end
    maximums = seen.transform_values { |turns| turns.each_cons(2).map { |a, b| b - a }.max }
    expect(maximums).to eq("memoization" => 4, "n_plus_one" => 4, "retention" => 4, "drill" => 4)
    puts "PRACTICE_MEASUREMENT contested=#{maximums.to_json} requests=#{requests.size} appearances=24"
  end
end
