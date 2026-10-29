module CodeReviewMultiFile
  SECTION = {
    "question" => "This change makes a customer's lifetime total a method instead of a stored column. What does it break, and how would you fix it?",
    "teaching_note" => "Look at where the job calls the new method, and count the queries one run makes.",
    "concept" => "n_plus_one",
    "scenario" => "a monthly loyalty report emailed to every customer",
    "file_1_path" => "app/models/customer.rb",
    "file_1_code" => <<~RUBY.strip,
      class Customer < ApplicationRecord
        has_many :orders

        def lifetime_total_cents
          orders.sum(:total_cents)
        end
      end
    RUBY
    "file_1_changed" => [ "def lifetime_total_cents", "orders.sum(:total_cents)" ],
    "file_2_path" => "app/jobs/loyalty_report_job.rb",
    "file_2_code" => <<~RUBY.strip,
      class LoyaltyReportJob < ApplicationJob
        def perform
          Customer.find_each do |customer|
            LoyaltyMailer.with(customer: customer, total: customer.lifetime_total_cents).report.deliver_later
          end
        end
      end
    RUBY
    "file_2_changed" => [],
    "answer_key" => {
      "issue" => "`orders.sum(:total_cents)` now runs once per customer inside `Customer.find_each` in the report job.",
      "why_it_matters" => "The report makes one sum query per customer, so it slows down as the customer list grows.",
      "fix" => "Compute every total in one grouped query in the job, or keep a stored total the model updates when an order changes."
    }
  }.freeze
end
