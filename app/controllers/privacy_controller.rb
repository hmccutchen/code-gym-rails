class PrivacyController < ApplicationController
  skip_before_action :require_login
  skip_before_action :require_provider

  # GET /privacy
  def show
    @facts = PrivacyNotice.facts
  end
end
