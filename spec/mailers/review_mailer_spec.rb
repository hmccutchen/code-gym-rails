require "rails_helper"

RSpec.describe ReviewMailer, type: :mailer do
  describe "#send_review" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

    let(:exercise) do
      user.daily_exercises.create!(
        date: Date.new(2026, 7, 10),
        generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
    end

    let(:daily_response) do
      user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.new(2026, 7, 10),
        answers: { "code_review" => "Found the N+1 in the loop" },
        submitted_at: Time.current,
        ai_review: {
          "code_review" => {
            "rating"           => "solid",
            "correct"          => "You spotted the N+1 query",
            "missed"           => "The missing index on user_id",
            "better_questions" => "What happens under concurrent writes?",
            "next_step"        => "Read about partial indexes",
            "improved_code"    => "User.includes(:posts)"
          }
        }
      )
    end

    let(:mail) { ReviewMailer.send_review(daily_response) }

    it "addresses the user with a dated subject" do
      expect(mail.to).to eq([ "dev@example.com" ])
      expect(mail.subject).to eq("Your Code Gym review — Friday, July 10")
    end

    it "renders every populated field with its label" do
      body = mail.body.encoded
      expect(body).to include("Code review")
      expect(body).to include("Rating: solid")
      expect(body).to include("What you got right:\n- You spotted the N+1 query")
      expect(body).to include("What you missed:\n- The missing index on user_id")
      expect(body).to include("Questions to ask yourself:\n- What happens under concurrent writes?")
      expect(body).to include("Next step: Read about partial indexes")
      expect(body).to include("Improved code:")
      expect(body).to include("User.includes(:posts)")
    end

    it "never renders improved_code for the architecture section" do
      daily_response.update!(
        concept_tags: { "architecture" => "other" },
        ai_review: { "architecture" => { "rating" => "solid", "improved_code" => "arch_improved_marker" } }
      )

      expect(mail.body.encoded).not_to include("arch_improved_marker")
      expect(mail.body.encoded).not_to include("Improved code:")
    end

    it "labels plan_review's improved_code as a revised plan, not as code" do
      daily_response.update!(
        concept_tags: { "plan_review" => "other" },
        ai_review: { "plan_review" => { "rating" => "solid", "improved_code" => "revised_plan_marker" } }
      )

      body = mail.body.encoded
      expect(body).to include("Revised plan:")
      expect(body).to include("revised_plan_marker")
      expect(body).not_to include("Improved code:")
    end

    it "skips blank fields" do
      daily_response.ai_review["code_review"]["improved_code"] = ""
      daily_response.ai_review["code_review"]["missed"] = ""
      expect(mail.body.encoded).not_to include("Improved code:")
      expect(mail.body.encoded).not_to include("What you missed:")
    end

    it "renders each entry of an array-shaped field as its own bullet" do
      daily_response.ai_review["code_review"]["missed"] = [
        "The missing index on user_id",
        "No transaction around the two writes"
      ]

      body = mail.body.encoded
      expect(body).to include("What you missed:\n- The missing index on user_id\n- No transaction around the two writes")
    end

    it "omits a list field that is an empty array" do
      daily_response.ai_review["code_review"]["missed"] = []
      expect(mail.body.encoded).not_to include("What you missed")
    end
  end
end
