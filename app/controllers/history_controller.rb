class HistoryController < ApplicationController
  include Pagy::Method

  # Pagy serves an out-of-range page as an empty result set by default, which
  # here would render the "no sessions yet" empty state to someone who has
  # plenty. Raise instead, and land them on the last real page.
  rescue_from Pagy::RangeError, with: :redirect_to_last_page

  # GET /history — all past submitted sessions, newest first. Drafts
  # (auto-saved but unsubmitted) stay on the dashboard, not here.
  def index
    @pagy, @responses = pagy(
      :offset,
      current_user.daily_responses.submitted
                  .includes(:user, :daily_exercise, :review_follow_ups)
                  .order(date: :desc),
      limit: DailyResponse::HISTORY_PAGE_SIZE,
      raise_range_error: true
    )
  end

  private

  def redirect_to_last_page(error)
    redirect_to history_path(page: error.pagy.last)
  end
end
