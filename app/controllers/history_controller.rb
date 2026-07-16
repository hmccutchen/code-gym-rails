class HistoryController < ApplicationController
  # GET /history — all past submitted sessions, newest first. Drafts
  # (auto-saved but unsubmitted) stay on the dashboard, not here.
  def index
    @responses = current_user.daily_responses
                             .includes(:user)
                             .where.not(submitted_at: nil)
                             .order(date: :desc)
  end
end
