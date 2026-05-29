# frozen_string_literal: true

module Public
  class TrackedLinksController < ApplicationController
    skip_before_action :authenticate, raise: false
    skip_before_action :set_company_scope, raise: false
    skip_before_action :set_current_attributes, raise: false

    FALLBACK_URL = 'https://renterinsight.com'

    # GET /t/:token
    # Handles BOTH tracked-link tokens (attachments/documents) and campaign content-link
    # tokens (Messaging::LinkTokenizer). Both systems mint /t/ URLs, and this route is
    # registered before campaign_tracking#click, so it must resolve both — otherwise
    # campaign content links 404.
    def show
      tracked_link = TrackedLink.find_by(token: params[:token])
      if tracked_link
        tracked_link.record_click!(
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        # Bridge into campaign analytics when this link belongs to a campaign email.
        CampaignSend.record_click_for_communication(tracked_link.communication_id)

        target = tracked_link.redirect_url
        if target.blank?
          render plain: 'Link has no destination', status: :unprocessable_entity
          return
        end
        redirect_to target, allow_other_host: true
        return
      end

      # Fallback: campaign content link tokenized by Messaging::LinkTokenizer.
      campaign_token = CampaignLinkToken.find_by(token: params[:token])
      if campaign_token
        campaign_token.record_click!
        cs = campaign_token.campaign_send
        if cs
          cs.update_columns(
            clicked_at: cs.clicked_at || Time.current,
            click_count: cs.click_count + 1
          )
        end
        redirect_to campaign_token.target_url, allow_other_host: true
        return
      end

      # Unknown token: send the recipient somewhere safe rather than a dead 404 page.
      redirect_to FALLBACK_URL, allow_other_host: true
    rescue => e
      Rails.logger.error "[TrackedLinks] redirect failed: #{e.message}"
      redirect_to FALLBACK_URL, allow_other_host: true
    end
  end
end
