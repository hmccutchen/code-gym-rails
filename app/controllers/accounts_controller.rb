class AccountsController < ApplicationController
  # Without this skip, a user who hasn't added an API key is redirected to
  # /setup before this action runs — and since the nav log-out button now
  # lives on this page, they would have no way to log out or delete.
  skip_before_action :require_api_key

  # GET /account
  def show; end
end
