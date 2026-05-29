# frozen_string_literal: true

module Webhooks
  class EmailTrackingController < ActionController::API
    # GET /webhooks/email/:communication_id/pixel.gif
    def pixel
      communication = Communication.find_by(id: params[:communication_id])

      if communication
        # Track every open event (count > 1 = re-opens).
        CommunicationEvent.track_open(
          communication,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        # Only stamp read_at on the first open.
        if communication.read_at.nil?
          communication.update_column(:read_at, Time.current)
        end

        # Bridge the open into campaign analytics (campaign_sends.opened_at/open_count),
        # which the campaign stats rollup and timeseries read. No-op for non-campaign emails.
        CampaignSend.record_open_for_communication(communication.id)

        Rails.logger.info "[EmailTracking] Email #{communication.id} opened by #{communication.to_address} (open ##{communication.communication_events.opened.count})"
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
