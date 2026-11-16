# frozen_string_literal: true

module Agreements
  # Sends a completed agreement's signed document by email and/or text as a
  # link. A sensitive agreement goes as a password-locked copy (see locked_link). The link is a signed, expiring token (no column, no migration) that
  # Public::AgreementFilesController turns into a short-lived S3 link, so the
  # PDF itself never sits in a public bucket and an old link stops working.
  class Share
    LINK_DAYS = 30
    PURPOSE = :agreement_share

    def self.shareable?(agreement)
      agreement.status == Agreement::STATUS_COMPLETED && agreement.sealed_document_url.present? &&
        agreement.share_window_open?
    end

    # A sensitive agreement (credit application) is shared as a password-locked
    # copy (LockedCopy). Its link works until the share window closes; the token
    # carries which locked file it opens. Returns [link, password].
    LOCKED_PURPOSE = :agreement_locked_share

    def self.locked_link(agreement)
      copy = LockedCopy.create!(agreement)
      token = locked_verifier.generate({ 'a' => agreement.id, 'k' => copy.key },
                                       expires_at: agreement.share_open_until, purpose: LOCKED_PURPOSE)
      ["#{Messaging::TrackingUrl.base}/agreement_files/#{token}", copy.password]
    end

    def self.locked_verifier = Rails.application.message_verifier(:agreement_locked_share)

    # [agreement, file to serve]: the locked copy for a locked link, else the signed PDF.
    def self.resolve(token)
      data = locked_verifier.verified(token, purpose: LOCKED_PURPOSE)
      if data.is_a?(Hash)
        agreement = Agreement.find_by(id: data['a'])
        return [nil, nil] unless agreement && PrivateFiles.owned_by?(data['k'], agreement.company_id)

        return [agreement, data['k']]
      end
      agreement = find_by_token(token)
      # A plain link never opens a sensitive agreement, even one made before it was marked.
      agreement && !agreement.sensitive? ? [agreement, agreement.sealed_document_url] : [nil, nil]
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      [nil, nil]
    end

    def self.link(agreement)
      token = agreement.signed_id(purpose: PURPOSE, expires_in: LINK_DAYS.days)
      # Customer-facing API links share one address switch (DMS_API_URL), so a
      # move to api.dealertide.com moves these with the email tracking links.
      "#{Messaging::TrackingUrl.base}/agreement_files/#{token}"
    end

    def self.find_by_token(token)
      Agreement.find_signed(token, purpose: PURPOSE)
    end

    # Sends a locked copy's password in its own text or email, never with the file,
    # then blanks it out of the saved message so it is stored nowhere afterwards.
    def self.send_password(agreement, user:, password:, channel:, to:)
      return { success: false, error: 'That is not a password from this screen.' } unless password.to_s.match?(LockedCopy::PASSWORD_FORMAT)
      return { success: false, error: channel == 'sms' ? 'Enter a mobile number.' : 'Enter an email address.' } if to.blank?

      company = agreement.company
      common = { communicable: agreement.contact || agreement.account || agreement, category: 'agreements',
                 portal_visible: false, send_async: false, sender_user_id: user&.id, user: user,
                 metadata: { 'agreement_id' => agreement.id, 'locked_copy_password' => true } }
      text = "Password to open #{agreement.title} from #{company.name}: #{password}"
      result = if channel == 'sms'
                 CommunicationService.send_sms(**common, to: to, body: text)
               else
                 CommunicationService.send_email(**common, to: to, subject: "Password for #{agreement.title} from #{company.name}",
                                                           body: "<p>#{ERB::Util.html_escape(text)}</p>")
               end
      result[:communication]&.update_columns(body: text.sub(password, '[password removed after sending]'))
      if result[:success]
        AgreementAuditLog.log!(agreement, 'password_sent', performed_by: user, metadata: { 'channel' => channel, 'to' => to })
        { success: true }
      else
        { success: false, error: result[:error].presence || 'Could not send the password.' }
      end
    rescue CommunicationService::OptOutError
      { success: false, error: "#{to} has opted out of #{channel == 'sms' ? 'texts' : 'email'}." }
    end

    # People the dialog offers: the agreement's contact, its signers and the
    # account's contacts, one row per person, only those with an email or phone.
    def self.recipients(agreement)
      rows = []
      digits = ->(p) { p.to_s.gsub(/\D/, '').last(10).presence }
      # A signer is usually also the contact: match on contact, email or phone
      # and fill in what the first row lacked instead of listing them twice.
      add = lambda do |name:, email:, phone:, contact_id: nil|
        email = email.presence
        phone = phone.presence
        next if email.nil? && phone.nil?

        same = rows.find do |r|
          (contact_id && r[:contact_id] == contact_id) ||
            (email && r[:email]&.casecmp?(email)) ||
            (phone && digits.call(r[:phone]) == digits.call(phone))
        end
        if same
          same[:email] ||= email
          same[:phone] ||= phone
          same[:contact_id] ||= contact_id
        else
          rows << { name: name.to_s.strip.presence || email || phone, email: email, phone: phone, contact_id: contact_id }
        end
      end
      contact_row = ->(c) { add.call(name: "#{c.first_name} #{c.last_name}", email: c.email, phone: c.try(:phone).presence || c.try(:mobile_phone), contact_id: c.id) }

      contact_row.call(agreement.contact) if agreement.contact
      agreement.agreement_signers.each do |s|
        add.call(name: s.name, email: s.email, phone: s.try(:phone), contact_id: s.try(:contact_id))
      end
      agreement.account&.contacts&.limit(25)&.each { |c| contact_row.call(c) }

      rows
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
      return result if result[:errors].any?

      if @agreement.sensitive?
        link, result[:password] = self.class.locked_link(@agreement)
      else
        link = self.class.link(@agreement)
      end

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
                                                     metadata: { 'sent' => result[:sent], 'locked' => @agreement.sensitive?,
                                                                 'link_until' => link_until.iso8601 })
      end
      result
    end

    private

    def communicable = @contact || @agreement.contact || @agreement.account || @agreement

    def link_until = @agreement.sensitive? ? @agreement.share_open_until : LINK_DAYS.days.from_now

    def until_text = link_until.strftime('%B %-d, %Y')

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
      return locked_email_args(to, note, link, esc) if @agreement.sensitive?
      body = <<~HTML
        #{note}<p>Here is your signed agreement: <strong>#{esc.call(@agreement.title)}</strong>.</p>
        <p><a href="#{esc.call(link)}">View the signed agreement</a></p>
        <p style="color:#666;font-size:12px">This link works for #{LINK_DAYS} days.</p>
        <p>#{esc.call(@company.name)}</p>
      HTML
      { to: to, subject: "Your signed agreement: #{@agreement.title}", body: body }
    end

    # Goes to a lender. Says nothing about the applicant beyond the document's name,
    # and never carries the password.
    def locked_email_args(to, note, link, esc)
      body = <<~HTML
        #{note}<p>#{esc.call(@company.name)} has sent you <strong>#{esc.call(@agreement.title)}</strong>.</p>
        <p><a href="#{esc.call(link)}">Download the PDF</a></p>
        <p>The PDF is password protected. #{esc.call(@company.name)} will give you the password separately.</p>
        <p style="color:#666;font-size:12px">This link works until #{until_text}.</p>
      HTML
      { to: to, subject: "#{@agreement.title} from #{@company.name}", body: body }
    end

    def sms_body(message, link)
      if @agreement.sensitive?
        lead = message.present? ? message.strip : "#{@company.name}: #{@agreement.title} (password protected, sent separately)."
        return "#{lead} #{link}"
      end

      lead = message.present? ? message.strip : "#{@company.name}: here is your signed agreement, #{@agreement.title}."
      "#{lead} #{link}"
    end
  end
end
