class HistoryController < ApplicationController
  # GET /history — all past submitted sessions, newest first. Drafts
  # (auto-saved but unsubmitted) stay on the dashboard, not here.
  def index
    @responses = current_user.daily_responses
                             .where.not(submitted_at: nil)
                             .includes(:daily_exercise)
                             .order(date: :desc)
  end
end
