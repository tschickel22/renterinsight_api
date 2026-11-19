# frozen_string_literal: true

# Consent to texts about the inquiry (backlog E105), kept the way a form keeps
# it: a transactional SMS CommunicationPreference with the record of how it was
# given. Forms write it (IntakeSubmission#record_sms_consent!); staff write it
# here for consent given away from a form; conversion carries it to the contact
# so the contact's consent page shows what the lead's did.
#
# The lead's sms_inquiry_consent column stays the switch the Lead Assistant,
# plays and Proactive Outreach read. STOP replies live on the category-less SMS
# preference (CommunicationOptOut) and nothing here can undo one.
class InquiryTextConsent
  CHANNEL = 'sms'
  CATEGORY = 'transactional'

  class << self
    def record!(lead, user:, basis:)
      now = Time.current
      lead.update_columns(sms_inquiry_consent: true, sms_inquiry_consent_at: now, updated_at: now)
      preference = CommunicationPreference.find_or_initialize_by(recipient: lead, channel: CHANNEL, category: CATEGORY)
      preference.assign_attributes(opted_in: true, opted_in_at: now, opted_out_at: nil, opted_out_reason: nil)
      preference.compliance_metadata = (preference.compliance_metadata || {}).except('removed_at', 'removed_by_name').merge(
        'source' => 'staff_entry', 'kind' => 'inquiry_texts', 'basis' => basis,
        'recorded_by_name' => name_of(user), 'recorded_at' => now.iso8601
      )
      preference.save!
    end

    def remove!(lead, user:, reason: nil)
      now = Time.current
      lead.update_columns(sms_inquiry_consent: false, sms_inquiry_consent_at: nil, updated_at: now)
      preference = CommunicationPreference.find_by(recipient: lead, channel: CHANNEL, category: CATEGORY)
      return unless preference

      preference.update!(opted_in: false, opted_out_at: now, opted_out_reason: reason.presence || 'Removed by staff',
                         compliance_metadata: (preference.compliance_metadata || {}).merge('removed_at' => now.iso8601, 'removed_by_name' => name_of(user)))
    end

    # Converting a lead. A record the contact already holds wins. A lead marked
    # without a preference (a list marked in bulk, an older lead) still carries.
    def carry!(lead, to:)
      return false if to.nil? || CommunicationPreference.exists?(recipient: to, channel: CHANNEL, category: CATEGORY)

      source = CommunicationPreference.find_by(recipient: lead, channel: CHANNEL, category: CATEGORY)
      if source
        copy = source.attributes.slice('opted_in', 'opted_in_at', 'opted_out_at', 'opted_out_reason', 'ip_address', 'user_agent')
        meta = (source.compliance_metadata || {}).merge('carried_from' => "Lead##{lead.id}", 'carried_at' => Time.current.iso8601)
        CommunicationPreference.create!(copy.merge(recipient: to, channel: CHANNEL, category: CATEGORY, compliance_metadata: meta))
      elsif lead.may_text_about_inquiry
        CommunicationPreference.create!(
          recipient: to, channel: CHANNEL, category: CATEGORY, opted_in: true, opted_in_at: lead.sms_inquiry_consent_at || lead.created_at,
          compliance_metadata: { 'source' => lead.sms_inquiry_consent ? 'lead_record' : 'older_form', 'kind' => 'inquiry_texts',
                                 'carried_from' => "Lead##{lead.id}", 'carried_at' => Time.current.iso8601 }
        )
      else
        return false
      end
      true
    rescue StandardError => e
      Rails.logger.error("[InquiryTextConsent] carry Lead##{lead&.id} -> #{to.class}##{to&.id}: #{e.class}: #{e.message}")
      false
    end

    # What the consent card shows, for a lead or a contact.
    def json(record)
      preference = CommunicationPreference.where(recipient: record, channel: CHANNEL, category: CATEGORY).order(updated_at: :desc).first
      meta = preference&.compliance_metadata || {}
      consented = record.is_a?(Lead) ? record.may_text_about_inquiry : preference&.opted_in == true
      {
        consented: consented,
        recorded: record.is_a?(Lead) ? record.sms_inquiry_consent : preference.present?,
        recordedAt: (record.try(:sms_inquiry_consent_at) if record.is_a?(Lead)) || preference&.opted_in_at,
        legacy: record.is_a?(Lead) ? (!record.sms_inquiry_consent && record.may_text_about_inquiry) : meta['source'] == 'older_form',
        source: meta['source'],
        basis: meta['basis'],
        recordedByName: meta['recorded_by_name'],
        consentText: meta['consent_text'],
        pageUrl: meta['page_url'],
        removedAt: meta['removed_at'],
        removedByName: meta['removed_by_name'],
        carriedFrom: meta['carried_from']
      }
    end

    def name_of(user)
      [user&.first_name, user&.last_name].compact_blank.join(' ').presence || user&.email
    end
  end
end
