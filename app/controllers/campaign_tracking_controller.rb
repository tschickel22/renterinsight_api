# frozen_string_literal: true

# Public, no-auth tracking endpoints for campaign click redirects and unsubscribe flow.
# Tokens are signed via Rails.application.message_verifier(:campaign_unsubscribe) for unsubscribe,
# and stored as opaque tokens in CampaignLinkToken for click redirects.

class CampaignTrackingController < ActionController::API
  # GET /t/:token — click redirect
  def click
    token = CampaignLinkToken.find_by(token: params[:token])
    return redirect_to(missing_url, allow_other_host: true) unless token

    token.record_click!
    cs = token.campaign_send
    if cs
      cs.update_columns(
        clicked_at: cs.clicked_at || Time.current,
        click_count: cs.click_count + 1
      )

      if cs.communication_id && cs.communication
        CommunicationEvent.track_click(
          cs.communication,
          url: token.target_url,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end

      begin
        CampaignEvent.create!(
          company_id: cs.company_id,
          campaign_id: cs.campaign_id,
          campaign_enrollment_id: cs.campaign_enrollment_id,
          campaign_send_id: cs.id,
          event_type: 'step_skipped',
          occurred_at: Time.current,
          payload: { url: token.target_url, ip: request.remote_ip }
        )
      rescue => _
        # non-fatal — Phase B will use the proper goal-trigger event
      end
    end

    redirect_to(token.target_url, allow_other_host: true)
  rescue => e
    Rails.logger.error "[CampaignTracking#click] #{e.message}"
    redirect_to(missing_url, allow_other_host: true)
  end

  # GET /u/:token — unsubscribe landing
  def unsubscribe_show
    cs = decode_unsubscribe_token(params[:token])
    return render(json: { error: 'Invalid or expired link' }, status: :not_found) unless cs

    enrollment = cs.campaign_enrollment
    render json: {
      campaign_name: cs.campaign.name,
      email_address: enrollment.email_address_snapshot,
      already_unsubscribed: enrollment.status == 'unsubscribed'
    }
  end

  # POST /u/:token — confirm unsubscribe
  def unsubscribe_confirm
    cs = decode_unsubscribe_token(params[:token])
    return render(json: { error: 'Invalid or expired link' }, status: :not_found) unless cs

    enrollment = cs.campaign_enrollment
    company_id = cs.company_id
    email = enrollment.email_address_snapshot

    ActiveRecord::Base.transaction do
      CampaignSuppression.find_or_create_by(company_id: company_id, email_address: email.to_s.downcase.strip) do |s|
        s.reason = 'unsubscribe'
        s.source_campaign_id = cs.campaign_id
      end

      enrollment.update!(status: 'unsubscribed', unsubscribed_at: Time.current)

      CampaignEnrollment
        .where(company_id: company_id, email_address_snapshot: email.to_s.strip)
        .where(status: %w[pending active paused])
        .where.not(id: enrollment.id)
        .update_all(status: 'unsubscribed', unsubscribed_at: Time.current)

      cs.update_columns(unsubscribed_at: Time.current)

      CampaignEvent.create!(
        company_id: company_id, campaign_id: cs.campaign_id,
        campaign_enrollment_id: enrollment.id, campaign_send_id: cs.id,
        event_type: 'unenrolled', occurred_at: Time.current,
        payload: { reason: 'unsubscribe' }
      )

      if cs.communication_id && cs.communication
        CommunicationEvent.track_unsubscribe(
          cs.communication,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end
    end

    render json: { success: true, message: 'You have been unsubscribed.' }
  rescue => e
    Rails.logger.error "[CampaignTracking#unsubscribe_confirm] #{e.message}"
    render json: { error: 'Unsubscribe failed' }, status: :internal_server_error
  end

  private

  def decode_unsubscribe_token(raw)
    decoded = Rails.application.message_verifier(:campaign_unsubscribe).verify(raw)
    send_id = decoded.is_a?(Hash) ? (decoded['s'] || decoded[:s]) : decoded
    CampaignSend.find_by(id: send_id)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def missing_url
    'https://renterinsight.com'
  end
end
