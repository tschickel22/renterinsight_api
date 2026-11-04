# frozen_string_literal: true

# The refusal every endpoint that sends a typed text or email gives to someone
# who opted out. A text is simply not sent. An email may still go when the
# person sending confirms it is about the customer's purchase rather than
# marketing, because a buyer who unsubscribed still needs their paperwork; the
# frontends ask, then send again with about_purchase.
module EnforcesCommunicationOptOut
  extend ActiveSupport::Concern

  private

  # @return [Hash, nil] the JSON to answer with, or nil when the send may go
  def communication_opt_out_refusal(channel:, company:, record:, address:, name: nil)
    return nil unless CommunicationOptOut.check(channel: channel, company: company, record: record, address: address).opted_out?

    who = name.presence || 'This person'
    if channel.to_s == 'sms'
      { ok: false, success: false, code: 'opted_out_sms', error: "#{who} opted out of texts, so this was not sent." }
    elsif ActiveModel::Type::Boolean.new.cast(params[:about_purchase])
      Rails.logger.info("[OptOut] user=#{current_user&.id} confirmed an email to #{record&.class&.name}##{record&.id} is about a purchase")
      nil
    else
      { ok: false, success: false, code: 'opted_out_email',
        error: "#{who} opted out of email. Send it only if it is about their purchase, not marketing." }
    end
  end

  def communication_recipient_name(record)
    return nil if record.blank?

    record.try(:first_name).presence || record.try(:name).presence
  end
end
