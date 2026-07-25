# frozen_string_literal: true

module Public
  # Public, no-auth "Refer a friend" flow. The token is a signed per-send token
  # (Rails.application.message_verifier(:campaign_referral)) minted by
  # EmailRenderer#build_urls, so a referral is attributed to whoever forwarded
  # the email. POST is gated by Turnstile (when configured) since it creates a
  # Lead from an unauthenticated form.
  class ReferralsController < ActionController::API
    # GET /api/referrals/:token — page context (who referred + dealership name)
    def show
      cs = decode_token(params[:token])
      return render(json: { error: 'Invalid or expired link' }, status: :not_found) unless cs

      render json: {
        company_name: cs.campaign.company&.name,
        referrer_first_name: referrer_first_name(cs),
        captcha_required: TurnstileVerifier.configured?,
        captcha_site_key: ENV['TURNSTILE_SITE_KEY']
      }
    end

    # POST /api/referrals/:token — capture the friend as a Lead + send an intro
    def create
      cs = decode_token(params[:token])
      return render(json: { error: 'Invalid or expired link' }, status: :not_found) unless cs

      if TurnstileVerifier.configured? &&
         !TurnstileVerifier.verify(params[:captcha_token], remote_ip: request.remote_ip)
        return render(json: { error: 'Captcha verification failed. Please try again.' }, status: :forbidden)
      end

      email = params[:friend_email].to_s.strip.downcase
      unless email.match?(URI::MailTo::EMAIL_REGEXP)
        return render(json: { error: 'A valid friend email is required.' }, status: :unprocessable_entity)
      end

      company  = cs.campaign.company
      referrer = cs.campaign_enrollment&.recipient
      ref_name = referrer_full_name(cs)

      # Don't email someone who has opted out.
      if CampaignSuppression.suppressed?(company.id, email)
        return render(json: { success: true, message: 'Thanks — but this person has opted out of emails.' })
      end

      first_name = params[:friend_first_name].to_s.strip.presence
      note       = params[:note].to_s.strip.presence

      # Dedupe: reuse an existing lead with this email rather than create a duplicate.
      lead = company.leads.where('LOWER(email) = ?', email).first
      created = false
      unless lead
        source = Source.find_or_create_by!(company_id: company.id, name: 'Referral') do |s|
          s.source_type = 'direct'
          s.is_active = true
        end
        lead = Lead.create!(
          company_id: company.id,
          first_name: first_name,
          email: email,
          status: 'new',
          source_id: source.id,
          owner_id: referrer.try(:owner_id),
          location_id: referrer.try(:location_id),
          notes: ["Referred by #{ref_name} (via campaign \"#{cs.campaign.name}\").",
                  (note && "Their note: #{note}")].compact.join("\n"),
          custom_field_values: {
            'referred_by_lead_id' => referrer&.id,
            'referred_by_campaign_send_id' => cs.id
          }.compact
        )
        created = true
      end

      send_intro_email(lead, company, ref_name) if created

      Rails.logger.info "[Public::Referrals] company=#{company.id} referrer=#{referrer&.id} -> lead #{lead.id} (#{email}) created=#{created}"
      render json: { success: true, message: 'Thanks for the referral — we\'ll reach out to them!' }
    rescue => e
      Rails.logger.error "[Public::Referrals#create] #{e.class}: #{e.message}"
      render json: { error: 'Something went wrong. Please try again.' }, status: :internal_server_error
    end

    private

    def decode_token(raw)
      decoded = Rails.application.message_verifier(:campaign_referral).verify(raw)
      send_id = decoded.is_a?(Hash) ? (decoded['s'] || decoded[:s]) : decoded
      CampaignSend.find_by(id: send_id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    def referrer_first_name(cs)
      cs.campaign_enrollment&.recipient.try(:first_name).presence || 'A friend'
    end

    def referrer_full_name(cs)
      r = cs.campaign_enrollment&.recipient
      return 'a friend' unless r
      [r.try(:first_name), r.try(:last_name)].compact.join(' ').strip.presence ||
        r.try(:name).presence || 'a friend'
    end

    def send_intro_email(lead, company, ref_name)
      greeting = lead.first_name.present? ? " #{ERB::Util.html_escape(lead.first_name)}" : ''
      body = <<~HTML
        <p>Hi#{greeting},</p>
        <p>#{ERB::Util.html_escape(ref_name)} thought you'd be interested in #{ERB::Util.html_escape(company.name)}.</p>
        <p>We'd love to help you find the right home — just reply to this email any time.</p>
      HTML
      CommunicationService.send_email(
        communicable: lead,
        to: lead.email,
        subject: "#{ref_name} thought you'd like #{company.name}",
        body: body,
        category: 'system',
        skip_preference_check: true,
        metadata: { source: 'referral' }
      )
    rescue => e
      Rails.logger.warn "[Public::Referrals] intro email failed for lead #{lead.id}: #{e.message}"
    end
  end
end
