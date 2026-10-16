# frozen_string_literal: true

module ApplicationCable
  # Live updates (pop-ups, import progress) open with the same sign-in token
  # the API takes, as ?token=. Until 2026-10-16 this trusted a user_id the
  # browser sent, and with none fell back to the first user in the database,
  # so anyone could listen to anyone's pop-ups.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      token = request.params[:token].presence
      decoded = token && JsonWebToken.decode(token)
      user = decoded && User.find_by(id: decoded[:user_id])
      user || reject_unauthorized_connection
    end
  end
end
