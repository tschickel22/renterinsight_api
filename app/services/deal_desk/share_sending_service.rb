# frozen_string_literal: true

# Sends a DealDeskShare to the customer via SMS / email. Mirrors the
# BrochureSendingService pattern (email + SMS in one call, activity tracked,
# opt-out handled) so it stays consistent with other outbound customer messages.
#
# Usage:
#   DealDesk::ShareSendingService.new(share).send(
#     delivery_methods: ['email', 'sms'],
#     to_email: 'buyer@example.com',
#     to_phone: '+15551234567',
#     custom_message: 'Here are the options we talked about'
#   )
module DealDesk
  class ShareSendingService
    class Error < StandardError; end

    attr_reader :share, :results

    def initialize(share)
      @share = share
      @results = { sent: [], failed: [], errors: [] }
    end

    def send(delivery_methods: ['email'], to_email: nil, to_phone: nil, custom_message: nil, **options)
      valid_methods = %w[email sms]
      invalid = delivery_methods - valid_methods
      raise ArgumentError, "Invalid delivery methods: #{invalid.join(', ')}" if invalid.any?

      if delivery_methods.include?('email') && to_email.blank?
        raise ArgumentError, 'Email address is required when sending via email'
      end
      if delivery_methods.include?('sms') && to_phone.blank?
        raise ArgumentError, 'Phone number is required when sending via SMS'
      end

      delivery_methods.each do |method|
        case method
        when 'email' then send_email(to: to_email, custom_message: custom_message, **options)
        when 'sms'   then send_sms(to: to_phone,  custom_message: custom_message, **options)
        end
      end

      @results
    end

    private

    def send_email(to:, custom_message:, **options)
      begin
        result = CommunicationService.send_email(
          communicable: share,
          to: to,
          subject: email_subject,
          body: email_body(custom_message: custom_message),
          category: 'deal_desk',
          metadata: base_metadata,
          portal_visible: false,
          send_async: false,
          **options
        )
        record_result('email', to, result)
      rescue CommunicationService::OptOutError
        record_optout('email', to)
      rescue => e
        record_error('email', to, e)
      end
    end

    def send_sms(to:, custom_message:, **options)
      begin
        result = CommunicationService.send_sms(
          communicable: share,
          to: to,
          body: sms_body(custom_message: custom_message),
          category: 'deal_desk',
          metadata: base_metadata,
          portal_visible: false,
          send_async: false,
          **options
        )
        record_result('sms', to, result)
      rescue CommunicationService::OptOutError
        record_optout('sms', to)
      rescue => e
        record_error('sms', to, e)
      end
    end

    def base_metadata
      {
        deal_desk_share_id: share.id,
        deal_id: share.deal_id,
        scenario_count: Array(share.scenario_ids).length
      }
    end

    def record_result(channel, to, result)
      if result[:success]
        @results[:sent] << { channel: channel, to: to, communication: result[:communication] }
      else
        @results[:errors] << result[:error]
        @results[:failed] << { channel: channel, to: to, reason: result[:error] }
      end
    end

    def record_optout(channel, to)
      @results[:errors] << "Recipient has opted out of #{channel} communications"
      @results[:failed] << { channel: channel, to: to, reason: 'Opted out' }
    end

    def record_error(channel, to, err)
      Rails.logger.error "[DealDesk::ShareSendingService] #{channel} to #{to} failed: #{err.message}"
      Rails.logger.error err.backtrace.first(5).join("\n")
      @results[:errors] << err.message
      @results[:failed] << { channel: channel, to: to, reason: err.message }
    end

    def email_subject
      buyer = share.deal.contact&.full_name || share.deal.customer_name || 'there'
      vehicle = share.snapshot.dig('vehicle', 'displayName') || 'your options'
      "#{buyer}, here are your options — #{vehicle}"
    end

    def email_body(custom_message:)
      base_url = ENV['FRONTEND_URL'] || ENV['API_BASE_URL'] || 'http://localhost:5173'
      url = share.public_url(base_url)
      vehicle = share.snapshot['vehicle'] || {}
      scenarios = Array(share.snapshot['scenarios'])
      company_name = share.company&.name || 'Your dealer'

      custom_html = custom_message.present? ? %(<p style="margin:0 0 16px;color:#374151;line-height:1.6;">#{ERB::Util.html_escape(custom_message)}</p>) : ''
      preview_img = vehicle['images']&.first
      preview_html = preview_img ? %(<div style="margin:16px 0;"><img src="#{preview_img}" alt="Home" style="width:100%;max-width:520px;border-radius:8px;" /></div>) : ''

      scenarios_rows = scenarios.map do |s|
        payment = s['monthly_payment']
        label   = s['label'] || 'Option'
        %(<tr><td style="padding:8px 0;color:#374151;">#{ERB::Util.html_escape(label)}</td><td style="padding:8px 0;text-align:right;font-weight:700;color:#111827;">#{payment ? "$#{format('%.2f', payment)}/mo" : ''}</td></tr>)
      end.join

      <<~HTML
        <!DOCTYPE html>
        <html><body style="font-family:Arial,sans-serif;line-height:1.6;color:#1f2937;max-width:600px;margin:0 auto;padding:20px;">
          #{custom_html}
          <p style="color:#374151;font-size:16px;margin:0 0 8px;">Here are the options we put together for you on the #{ERB::Util.html_escape(vehicle['displayName'].to_s)}.</p>
          #{preview_html}
          <div style="background:#f3f4f6;border-radius:8px;padding:16px;margin:16px 0;">
            <table style="width:100%;border-collapse:collapse;">#{scenarios_rows}</table>
          </div>
          <div style="text-align:center;margin:24px 0;">
            <a href="#{url}" style="display:inline-block;padding:14px 32px;background:#2563eb;color:white;text-decoration:none;border-radius:8px;font-weight:700;">View my options</a>
          </div>
          <p style="color:#6b7280;font-size:14px;text-align:center;margin-top:24px;">#{company_name}</p>
        </body></html>
      HTML
    end

    def sms_body(custom_message:)
      base_url = ENV['FRONTEND_URL'] || ENV['API_BASE_URL'] || 'http://localhost:5173'
      url = share.public_url(base_url)
      vehicle = share.snapshot.dig('vehicle', 'displayName') || 'your home'
      parts = []
      parts << custom_message if custom_message.present?
      parts << "Your options on #{vehicle}: #{url}"
      parts.join("\n\n")
    end
  end
end
