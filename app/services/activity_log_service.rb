# frozen_string_literal: true

class ActivityLogService
  def self.log(company:, user: nil, trackable: nil, account: nil, location: nil, action:, module_name:, description:, changes_made: {}, metadata: {}, ip_address: nil)
    ActivityLog.create!(
      company: company,
      user: user || Current.user,
      trackable: trackable,
      account_id: account&.id || account_id_from(trackable),
      location_id: location&.id || location_id_from(trackable),
      action: action,
      module_name: module_name,
      entity_type_label: trackable&.class&.name&.titleize,
      description: description,
      changes_made: changes_made.deep_stringify_keys,
      metadata: metadata.deep_stringify_keys,
      ip_address: ip_address || Current.try(:ip_address)
    )
  rescue => e
    Rails.logger.error("[ActivityLogService] Failed to log activity: #{e.message}")
  end

  def self.log_email_sent(company:, user: nil, recipient:, subject:, trackable: nil)
    log(
      company: company,
      user: user,
      trackable: trackable,
      action: 'email_sent',
      module_name: 'communications',
      description: "Sent email to #{recipient}: #{subject}",
      metadata: { recipient: recipient, subject: subject }
    )
  end

  def self.log_sms_sent(company:, user: nil, recipient:, body:, trackable: nil)
    log(
      company: company,
      user: user,
      trackable: trackable,
      action: 'sms_sent',
      module_name: 'communications',
      description: "Sent SMS to #{recipient}",
      metadata: { recipient: recipient, body: body.truncate(200) }
    )
  end

  def self.log_call(company:, user:, contact:, duration: nil, notes: nil)
    log(
      company: company,
      user: user,
      trackable: contact,
      action: 'call_logged',
      module_name: 'communications',
      description: "Logged call with #{contact.try(:full_name) || contact.try(:name) || 'contact'}",
      metadata: { duration: duration, notes: notes }.compact
    )
  end

  def self.log_document_attached(company:, user:, document_name:, trackable:)
    log(
      company: company,
      user: user,
      trackable: trackable,
      action: 'document_attached',
      module_name: 'general',
      description: "Attached document '#{document_name}' to #{trackable.class.name.titleize.downcase}",
      metadata: { document_name: document_name }
    )
  end

  def self.log_agreement_sent(company:, user:, agreement:, recipient:)
    log(
      company: company,
      user: user,
      trackable: agreement,
      action: 'agreement_sent',
      module_name: 'finance',
      description: "Sent agreement to #{recipient}",
      metadata: { recipient: recipient }
    )
  end

  def self.log_payment_received(company:, user: nil, payment:, amount:)
    log(
      company: company,
      user: user,
      trackable: payment,
      action: 'payment_received',
      module_name: 'finance',
      description: "Payment received: $#{'%.2f' % amount}",
      metadata: { amount: amount }
    )
  end

  def self.log_conversion(company:, user:, from_entity:, to_entity:, description:)
    log(
      company: company,
      user: user,
      trackable: to_entity,
      action: 'converted',
      module_name: 'crm',
      description: description,
      metadata: {
        from_type: from_entity.class.name,
        from_id: from_entity.id,
        to_type: to_entity.class.name,
        to_id: to_entity.id
      }
    )
  end

  private

  def self.account_id_from(trackable)
    return nil unless trackable
    case trackable.class.name
    when 'Account' then trackable.id
    when 'Contact', 'Deal', 'ServiceTicket' then trackable.try(:account_id)
    when 'Lead' then trackable.try(:converted_account_id)
    when 'Quote' then trackable.try(:account_id) || trackable.try(:deal)&.try(:account_id)
    when 'Invoice' then trackable.try(:account_id) || trackable.try(:deal)&.try(:account_id)
    when 'Communication' then trackable.try(:communicable)&.try(:account_id)
    else trackable.try(:account_id)
    end
  end

  def self.location_id_from(trackable)
    trackable&.try(:location_id)
  end
end
