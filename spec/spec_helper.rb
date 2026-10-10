RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # One file per parallel_tests process, since concurrent writers to one file would lose results.
  config.example_status_persistence_file_path = "spec/examples#{ENV["TEST_ENV_NUMBER"]}.txt"
end
