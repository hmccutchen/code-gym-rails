module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      User.signed_in(request.session[:user_id]) || reject_unauthorized_connection
    end
  end
end
