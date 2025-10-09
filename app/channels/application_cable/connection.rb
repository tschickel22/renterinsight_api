# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
      logger.info "[ActionCable] User #{current_user&.id} connected"
    end

    private

    def find_verified_user
      # In a real app, you'd verify the user from a token or session
      # For now, we'll use the user_id from params
      user_id = request.params[:user_id]
      
      if user_id && (user = User.find_by(id: user_id))
        user
      else
        # For development, return first user if no auth
        User.first || reject_unauthorized_connection
      end
    end
  end
end
