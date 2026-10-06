require "rails_helper"

# The test environment uses :null_store, whose #increment returns nil, so no
# limit trips in the rest of the suite. These examples swap in a real store.
# Requests here are refused by each action's own checks after the limit has
# counted them, so no provider is called. The limits guard a trial's house
# key, so the account is a trial unless an example says otherwise.
RSpec.describe "Per-user request limits", type: :request do
  let(:user) { create_trial_user }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    login_as(user)
  end

  def critique = post(pseudocode_critique_responses_path, params: {}, as: :json)

  describe "provider-calling endpoints" do
    it "refuses the request past the hourly limit with a JSON error the page can show" do
      ProviderCallLimits::HOURLY.times { critique }
      expect(response).not_to have_http_status(:too_many_requests)

      critique

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to match(/limit on AI requests/)
    end

    it "shares the count across controllers" do
      ProviderCallLimits::HOURLY.times { critique }

      post explain_differently_concept_reference_path(0), as: :json

      expect(response).to have_http_status(:too_many_requests)
    end

    # One request to each action, then a critique that is over the limit only
    # if that request counted. Each is refused by its own checks after the
    # limit has counted it, so no provider is called.
    {
      "duck_thread" => -> { post duck_thread_responses_path, params: {}, as: :json },
      "follow_ups" => -> { post follow_ups_response_path(0), params: {}, as: :json },
      "explain_differently on a review" => -> { post explain_differently_response_path(0), params: {}, as: :json },
      "explain_differently on a concept reference" => -> { post explain_differently_concept_reference_path(0), as: :json }
    }.each do |label, request|
      it "counts #{label} toward the shared limit" do
        (ProviderCallLimits::HOURLY - 1).times { critique }
        instance_exec(&request)
        expect(response).not_to have_http_status(:too_many_requests)

        critique

        expect(response).to have_http_status(:too_many_requests)
      end
    end

    it "keeps counting across hours toward the daily limit" do
      ProviderCallLimits::DAILY.times do |n|
        travel(61.minutes) if (n % ProviderCallLimits::HOURLY).zero? && n.positive?
        critique
      end
      travel(61.minutes)

      critique

      expect(response).to have_http_status(:too_many_requests)
    end

    it "counts each user separately" do
      ProviderCallLimits::HOURLY.times { critique }

      login_as(create_trial_user(email: "other@example.com"))
      critique

      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "never limits an account with its own key" do
      login_as(create_user_with_key(email: "own@example.com"))

      (ProviderCallLimits::DAILY + 1).times { critique }

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe "POST /generate" do
    it "refuses a press past the hourly limit without queueing a generation" do
      DailyExercisesController::GENERATE_PER_HOUR.times { post generate_path }

      expect { post generate_path }.not_to have_enqueued_job(GenerateDailyExercisesJob)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/several times in the last hour/)
    end

    it "never limits an account with its own key" do
      login_as(create_user_with_key(email: "own@example.com"))
      (DailyExercisesController::GENERATE_PER_HOUR + 1).times { post generate_path }

      expect(flash[:alert]).to be_nil
    end
  end

  describe "Learn write-ups" do
    let(:concept_path) { prepare_learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one") }

    before { user.update!(language: "ruby_rails") }

    it "answers a script's request past the limit with JSON" do
      LearnController::PREPARE_PER_HOUR.times { post concept_path, as: :json }

      expect { post concept_path, as: :json }.not_to have_enqueued_job(GenerateConceptReferenceJob)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to match(/several write-ups/)
    end

    it "counts the ladder button with the per-concept requests and redirects it back to Setup" do
      LearnController::PREPARE_PER_HOUR.times { post concept_path, as: :json }

      expect { post prepare_learn_ladders_path, headers: { "HTTP_REFERER" => setup_url } }
        .not_to have_enqueued_job(GenerateConceptReferenceJob)
      expect(response).to redirect_to(setup_url)
      expect(flash[:alert]).to match(/several write-ups/)
    end

    it "counts the backfill button with the per-concept requests and redirects it" do
      LearnController::PREPARE_PER_HOUR.times { post concept_path, as: :json }

      post prepare_learn_path

      expect(response).to redirect_to(learn_path)
      expect(flash[:alert]).to match(/several write-ups/)
    end

    it "never limits an account with its own key" do
      own = create_user_with_key(email: "own@example.com")
      own.update!(language: "ruby_rails")
      login_as(own)

      (LearnController::PREPARE_PER_HOUR + 1).times { post concept_path, as: :json }

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end
end
