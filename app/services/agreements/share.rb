# frozen_string_literal: true

module Agreements
  # Sends a completed agreement's signed document by email and/or text as a
  # link. The link is a signed, expiring token (no column, no migration) that
  # Public::AgreementFilesController turns into a short-lived S3 link, so the
  # PDF itself never sits in a public bucket and an old link stops working.
  class Share
    LINK_DAYS = 30
    PURPOSE = :agreement_share

    def self.shareable?(agreement)
      agreement.status == Agreement::STATUS_COMPLETED && agreement.sealed_document_url.present?
    end

    def self.link(agreement)
      token = agreement.signed_id(purpose: PURPOSE, expires_in: LINK_DAYS.days)
      "#{(ENV['RAILS_API_URL'].presence || 'https://localhost:3001').chomp('/')}/agreement_files/#{token}"
    end

    def self.find_by_token(token)
      Agreement.find_signed(token, purpose: PURPOSE)
    end

    # People the dialog offers: the agreement's contact, its signers and the
    # account's contacts, one row per person, only those with an email or phone.
    def self.recipients(agreement)
      rows = []
      add = lambda do |name:, email:, phone:, contact_id: nil|
        next if email.blank? && phone.blank?

        rows << { name: name.to_s.strip.presence || email || phone, email: email.presence, phone: phone.presence,
                  contact_id: contact_id }
      end
      contact_row = ->(c) { add.call(name: "#{c.first_name} #{c.last_name}", email: c.email, phone: c.try(:phone).presence || c.try(:mobile_phone), contact_id: c.id) }

      contact_row.call(agreement.contact) if agreement.contact
      agreement.agreement_signers.each do |s|
        add.call(name: s.name, email: s.email, phone: s.try(:phone), contact_id: s.try(:contact_id))
      end
      agreement.account&.contacts&.limit(25)&.each { |c| contact_row.call(c) }

      rows.uniq { |r| r[:contact_id] || [r[:email]&.downcase, r[:phone]] }
    end

    def initialize(agreement, user:, contact: nil)
      @agreement = agreement
      @company = agreement.company
      @user = user
      @contact = contact
    end

    # @return [Hash] { sent: [{channel:, to:}], errors: [String] }
    def deliver(channels:, to_email:, to_phone:, message:)
      result = { sent: [], errors: [] }
      channels = channels.map(&:to_s) & %w[email sms]
      result[:errors] << 'Choose email, text or both.' if channels.empty?
      link = self.class.link(@agreement)

      if channels.include?('email')
        if to_email.blank? then result[:errors] << 'Enter an email address.'
        else send_one(result, 'email', to_email) { email_args(to_email, message, link) }
        end
      end
      if channels.include?('sms')
        if to_phone.blank? then result[:errors] << 'Enter a mobile number.'
        else send_one(result, 'sms', to_phone) { { to: to_phone, body: sms_body(message, link) } }
        end
      end

      if result[:sent].any?
        AgreementAuditLog.log!(@agreement, 'shared', performed_by: @user,
                                                     metadata: { 'sent' => result[:sent], 'link_days' => LINK_DAYS })
      end
      result
    end

    private

    def communicable = @contact || @agreement.contact || @agreement.account || @agreement

    def send_one(result, channel, to)
      args = yield
      common = { communicable: communicable, category: 'agreements', portal_visible: false, send_async: false,
                 sender_user_id: @user&.id, user: @user,
                 metadata: { 'agreement_id' => @agreement.id, 'agreement_number' => @agreement.agreement_number } }
      r = if channel == 'email'
            CommunicationService.send_email(**common, **args)
          else
            CommunicationService.send_sms(**common, **args)
          end
      if r[:success]
        result[:sent] << { channel: channel, to: to }
      else
        result[:errors] << (r[:error].presence || "Could not send the #{channel == 'sms' ? 'text' : 'email'}.")
      end
    rescue CommunicationService::OptOutError
      result[:errors] << "#{to} has opted out of #{channel == 'sms' ? 'texts' : 'email'}."
    rescue StandardError => e
      Rails.logger.error("[Agreements::Share] #{@agreement.id} #{channel}: #{e.class} #{e.message}")
      result[:errors] << "Could not send the #{channel == 'sms' ? 'text' : 'email'}."
    end

    def email_args(to, message, link)
      esc = ->(t) { ERB::Util.html_escape(t.to_s) }
      note = message.present? ? "<p>#{esc.call(message).gsub("\n", '<br>')}</p>" : ''
      body = <<~HTML
        #{note}<p>Here is your signed agreement: <strong>#{esc.call(@agreement.title)}</strong>.</p>
        <p><a href="#{esc.call(link)}">View the signed agreement</a></p>
        <p style="color:#666;font-size:12px">This link works for #{LINK_DAYS} days.</p>
        <p>#{esc.call(@company.name)}</p>
      HTML
      { to: to, subject: "Your signed agreement: #{@agreement.title}", body: body }
    end

    def sms_body(message, link)
      lead = message.present? ? message.strip : "#{@company.name}: here is your signed agreement, #{@agreement.title}."
      "#{lead} #{link}"
    end
  end
end
