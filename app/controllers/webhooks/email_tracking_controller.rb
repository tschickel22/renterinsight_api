# frozen_string_literal: true

module Webhooks
  class EmailTrackingController < ActionController::API
    # GET /webhooks/email/:communication_id/pixel.gif
    def pixel
      communication = Communication.find_by(id: params[:communication_id])
      
      if communication && communication.read_at.nil?
        # Mark as read
        communication.update!(read_at: Time.current)
        
        # Track event
        CommunicationEvent.track_open(
          communication,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        
        Rails.logger.info "[EmailTracking] Email #{communication.id} opened by #{communication.to_address}"
      end
      
      # Serve 1x1 transparent GIF
      send_data(
        Base64.decode64('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'),
        type: 'image/gif',
        disposition: 'inline'
      )
    rescue => e
      Rails.logger.error "[EmailTracking] Error: #{e.message}"
      head :ok  # Always return 200 to avoid errors in email client
    end
  end
end
