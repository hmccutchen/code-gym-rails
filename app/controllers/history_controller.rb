class HistoryController < ApplicationController
  include Pagy::Method

  # Pagy's default empty page would show "no sessions yet" to someone who has some; land on the last real page instead.
  rescue_from Pagy::RangeError, with: :redirect_to_last_page

  # GET /history — submitted sessions only; drafts stay on the dashboard.
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
    redirect_to history_page_path(error.pagy.last)
  end
end
