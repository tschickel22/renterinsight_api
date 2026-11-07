# frozen_string_literal: true

module Public
  # A rep's appointments as a subscribable calendar (E96 phase 2). The token
  # in the address is the only key; the rep can replace it from My
  # availability, which stops the old link.
  class CalendarFeedsController < ActionController::API
    def show
      token = params[:token].to_s
      user = User.find_by(calendar_feed_token: token) if token.match?(/\A[\w-]{20,64}\z/)
      return head :not_found unless user&.active?

      response.headers['Cache-Control'] = 'private, max-age=300'
      send_data CalendarFeeds::IcsOut.new(user).to_ics, type: 'text/calendar; charset=utf-8', disposition: 'inline',
                                                        filename: 'appointments.ics'
    end
  end
end
