# frozen_string_literal: true

# Folds a repeat inquiry into the record it matched instead of creating a
# duplicate lead. A returning inquiry is NOT a no-op: this fills blank fields,
# writes what came in as a note, and tells a person, so the dealer hears that
# someone re-engaged instead of the inquiry vanishing.
#
# Built for the partner API (Zapier) and shared with direct Facebook Lead Ads,
# so both inbound paths treat a returning person the same way. Callers supply
# what differs between them: the label notes and notifications carry, the raw
# form answers, and who else may be told when the record has no owner.
#
# Every match type gets a note and an owner notification. It used to be
# lead-only: an inquiry whose email/phone belonged to a CONTACT or an ACCOUNT
# did nothing at all, no note, no notify, no lead, and no search could find it
# because the person's name was never written anywhere.
#
# Entirely best-effort and self-contained in rescue: enrichment and
# notification failures must never turn a successful dedupe into an error for
# the caller.
class InboundInquiryAbsorber
  # Activity model + its foreign key, per match type. All three implement the
  # same reminder-on-create contract.
  REPEAT_INQUIRY_ACTIVITY = {
    lead: [LeadActivity, :lead_id],
    contact: [ContactActivity, :contact_id],
    account: [AccountActivity, :account_id]
  }.freeze

  # Frontend detail-page paths, matching GlobalSearch's urlMap.
  REPEAT_INQUIRY_PATH = {
    lead: '/crm/leads',
    contact: '/contacts',
    account: '/accounts'
  }.freeze

  # Blank-only fill list for repeat inquiries: never overwrites existing data.
  FILLABLE_FROM_INQUIRY = %i[
    first_name last_name email phone
    budget_range purchase_timeframe rv_experience
    preferred_contact_method interests_requirements
  ].freeze

  # Contacts share the person fields but not the lead qualification ones
  # (rv_experience, purchase_timeframe and friends aren't contact columns).
  CONTACT_FILLABLE_FROM_INQUIRY = %i[
    first_name last_name email phone budget_range
  ].freeze

  # source_label:         what notes and notifications say it came through
  # raw_answers:          unmapped form answers, for the note and the email
  # recipient_candidates: callable(attrs) returning user ids to try after the
  #                       record's owner and before the intake form's watcher
  # origin:               metadata tag on the notification email
  def initialize(company:, source_label:, raw_answers: {}, recipient_candidates: nil, origin: 'inbound')
    @company = company
    @source_label = source_label.presence || 'API'
    @raw_answers = raw_answers.is_a?(Hash) ? raw_answers : {}
    @recipient_candidates = recipient_candidates || ->(_attrs) { [] }
    @origin = origin
  end

  def call(match, attrs, cf_values: {}, cf_consumed: [])
    # Captured before enrichment: enrichment fills blank name fields from the
    # payload, after which "who inquired" and "whose record this is" would look
    # identical even when they weren't.
    inbound_name = [attrs[:first_name], attrs[:last_name]].compact.join(' ').strip
    record = match.record

    enriched =
      case match.type
      when :lead
        enrich_lead_from_inquiry!(record, attrs, cf_values: cf_values, cf_consumed: cf_consumed)
      when :contact
        enrich_contact_from_inquiry!(record, attrs, cf_consumed: cf_consumed)
      else
        # Accounts are organization-shaped: a person's name, email and phone
        # don't belong on their columns. Record the inquiry as a note and
        # notify; don't touch the account's own fields.
        write_inbound_note!('account', record.id, repeat_inquiry_note(attrs, cf_consumed))
        false
      end

    notify_repeat_inquiry(record, inbound_name: inbound_name, match_type: match.type, attrs: attrs)
    Rails.logger.info "[InboundInquiryAbsorber] Absorbed repeat inquiry from " \
                      "'#{inbound_name.presence || 'unnamed'}' (#{attrs[:email] || attrs[:phone]}) " \
                      "into #{match.type} #{record.id} '#{match.name}' " \
                      "(enriched=#{enriched}, matched_on=#{match.matched}) via '#{@source_label}'"
  rescue => e
    Rails.logger.error "[InboundInquiryAbsorber] failed for #{match.type} #{match.record&.id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end

  private

  # Contact counterpart of #enrich_lead_from_inquiry!: fill blanks only, append
  # the inquiry to the notes field, and write a Notes-tab entry.
  #
  # Custom fields are deliberately not applied: cf_values was resolved against
  # the company's LEAD custom fields, which are a different set from its contact
  # fields. Those values still reach the note, so the answers aren't lost.
  def enrich_contact_from_inquiry!(contact, attrs, cf_consumed: [])
    CONTACT_FILLABLE_FROM_INQUIRY.each do |field|
      next unless contact.has_attribute?(field)
      val = attrs[field]
      contact[field] = val if val.present? && contact[field].blank?
    end

    summary = inbound_inquiry_summary(attrs, cf_consumed)
    if summary.present? && contact.has_attribute?(:notes)
      stamp = Time.current.strftime('%Y-%m-%d %H:%M %Z')
      entry = "[#{stamp}] Repeat inquiry via #{@source_label}\n#{summary}"
      contact.notes = [contact.notes.presence, entry].compact.join("\n\n")
    end

    changed = contact.changed?
    contact.save if changed

    write_inbound_note!('contact', contact.id, repeat_inquiry_note(attrs, cf_consumed))
    changed
  end

  # Notes-tab body for an absorbed inquiry. Same shape the lead path writes, so
  # the Notes tab reads identically on any record type.
  def repeat_inquiry_note(attrs, cf_consumed)
    summary = inbound_inquiry_summary(attrs, cf_consumed)
    return nil if summary.blank?

    "🔁 REPEAT INQUIRY via #{@source_label}\n\n#{summary}"
  end

  # Fill any blank contact/qualification fields from the new payload (never
  # overwrite existing data) and append a timestamped note capturing what came
  # in. Saving fires the lead's normal emit_workflow_updated hook. Returns true
  # if the record changed.
  def enrich_lead_from_inquiry!(lead, attrs, cf_values: {}, cf_consumed: [])
    FILLABLE_FROM_INQUIRY.each do |field|
      val = attrs[field]
      lead[field] = val if val.present? && lead[field].blank?
    end

    apply_custom_fields_from_inquiry!(lead, cf_values)

    # Anything that mapped to a custom field is already on the record, so keep
    # it out of the note rather than recording it twice.
    summary = inbound_inquiry_summary(attrs, cf_consumed)
    if summary.present?
      stamp = Time.current.strftime('%Y-%m-%d %H:%M %Z')
      entry = "[#{stamp}] Repeat inquiry via #{@source_label}\n#{summary}"
      lead.notes = [lead.notes.presence, entry].compact.join("\n\n")
    end

    changed = lead.changed?
    lead.save if changed

    # Written after the save so a failed enrichment doesn't leave an orphan
    # note, and unconditionally on summary (not on `changed`): a repeat inquiry
    # that adds no new field values is still something the dealer needs to see.
    if summary.present?
      write_inbound_note!('lead', lead.id, "🔁 REPEAT INQUIRY via #{@source_label}\n\n#{summary}")
    end

    changed
  end

  # Blank-only merge of dealer-defined custom fields, mirroring the
  # FILLABLE_FROM_INQUIRY rule: a repeat inquiry fills gaps, it never overwrites
  # an answer already on the record.
  def apply_custom_fields_from_inquiry!(lead, cf_values)
    return if cf_values.blank?

    existing = (lead.custom_field_values || {}).deep_stringify_keys
    merged = existing.dup
    cf_values.each do |k, v|
      key = k.to_s
      merged[key] = v if v.present? && existing[key].blank?
    end

    lead.custom_field_values = merged unless merged == existing
  end

  # Human-readable digest of the inbound payload for the note and email,
  # including the raw form answers (e.g. Facebook lead-ad questions) that
  # aren't mapped to columns.
  def inbound_inquiry_summary(attrs, skip_keys = [])
    skipped = Array(skip_keys).map { |k| k.to_s.downcase }.to_set
    lines = []
    name = [attrs[:first_name], attrs[:last_name]].compact.join(' ').strip
    lines << "Name: #{name}"                                   if name.present?
    lines << "Email: #{attrs[:email]}"                         if attrs[:email].present?
    lines << "Phone: #{attrs[:phone]}"                         if attrs[:phone].present?
    lines << "Interest: #{attrs[:interests_requirements]}"     if attrs[:interests_requirements].present?
    lines << "Timeframe: #{attrs[:purchase_timeframe]}"        if attrs[:purchase_timeframe].present?
    lines << "Notes: #{attrs[:notes]}"                         if attrs[:notes].present?

    skip = %w[full_name email phone].to_set | skipped
    @raw_answers.each do |k, v|
      next if v.blank? || skip.include?(k.to_s.downcase)
      lines << "#{k}: #{v}"
    end

    lines.join("\n")
  rescue => e
    Rails.logger.error "[InboundInquiryAbsorber] inbound_inquiry_summary failed: #{e.message}"
    nil
  end

  # Owner-facing notification for a repeat inquiry: in-app toast/bell via an
  # activity + email, matching the intake :existing_lead path.
  #
  # `inbound_name` is who the payload said was inquiring. It matters when it
  # differs from the matched record: dedupe matches on email/phone, so a shared
  # household number folds Tia May's inquiry into Bob Smith's lead, and every
  # notification then said "Bob Smith".
  def notify_repeat_inquiry(record, inbound_name: nil, match_type: :lead, attrs: {})
    notify_user = repeat_inquiry_recipient(record, attrs)
    return unless notify_user

    name = repeat_inquiry_display_name(matched_record_name(record, match_type), inbound_name)
    noun = match_type.to_s.capitalize

    # Creating the activity IS the send. Lead/Contact/AccountActivity all share
    # an after_create :schedule_reminders that fires for activity_type
    # 'reminder' with a reminder_time, and because that time is now it calls
    # ActivityReminderService.send_reminder immediately. Calling the service
    # again delivered every repeat inquiry twice: two bell notifications AND two
    # Twilio SMS to the owner.
    activity_class, foreign_key = REPEAT_INQUIRY_ACTIVITY.fetch(match_type)
    activity_class.create!(
      foreign_key => record.id,
      user_id: notify_user.id,
      assigned_to_id: notify_user.id,
      activity_type: 'reminder',
      subject: "Repeat Inquiry on Existing #{noun}: #{name}",
      description: "Existing #{match_type} re-engaged via #{@source_label}. " \
                   "Contact: #{record.try(:email) || record.try(:phone) || 'N/A'}",
      priority: 'high',
      status: 'pending',
      reminder_time: Time.current,
      reminder_sent: false
    )

    send_repeat_inquiry_email(record, notify_user, inbound_name: inbound_name, match_type: match_type)
  rescue => e
    Rails.logger.error "[InboundInquiryAbsorber] notify_repeat_inquiry failed for #{match_type} #{record.id}: #{e.class} - #{e.message}"
  end

  # Who hears about a repeat inquiry, first match wins:
  #
  #   1. The matched record's owner: the person who holds the relationship.
  #   2. Whatever the caller names (an API key's designated owner and rotation,
  #      a Facebook page's default owner).
  #   3. The lead intake form's notified user: the dealer already told us who
  #      watches inbound leads there, so it's the right last resort.
  #
  # Candidates are gathered before any is checked, so a caller's rotation takes
  # its turn exactly as it would for a new lead.
  def repeat_inquiry_recipient(record, attrs)
    candidate_ids = [record.try(:owner_id)]
    candidate_ids.concat(Array(@recipient_candidates.call(attrs)))
    candidate_ids << intake_form_notified_user_id(attrs)

    candidate_ids.compact.each do |id|
      user = User.find_by(id: id, company_id: @company.id, status: 'active')
      return user if user
    end
    nil
  end

  # The intake form whose notified user should hear about inbound leads we
  # couldn't route any other way. Prefer the form bound to this inquiry's
  # location, then the one bound to its source, then the most recently touched.
  def intake_form_notified_user_id(attrs)
    forms = IntakeForm.where(company_id: @company.id, is_active: true)
                      .where.not(notified_user_id: nil)
                      .order(updated_at: :desc)
                      .limit(25)
                      .to_a
    return nil if forms.empty?

    form = forms.find { |f| attrs[:location_id].present? && f.location_id == attrs[:location_id].to_i } ||
           forms.find { |f| attrs[:source_id].present? && f.source_id == attrs[:source_id].to_i } ||
           forms.first

    Rails.logger.info "[InboundInquiryAbsorber] Repeat-inquiry notify falling back to intake form " \
                      "#{form.id} ('#{form.name}') notified_user #{form.notified_user_id}"
    form.notified_user_id
  rescue => e
    Rails.logger.error "[InboundInquiryAbsorber] intake_form_notified_user_id failed: #{e.class} - #{e.message}"
    nil
  end

  # Accounts carry a single `name`; people carry first + last.
  def matched_record_name(record, match_type)
    return record.try(:name).to_s.strip if match_type == :account

    [record.try(:first_name), record.try(:last_name)].compact.join(' ').strip
  end

  # "Tia May (matched to existing record: Bob Smith)" when the inbound name is
  # someone else, otherwise just the one name. Compared case- and
  # whitespace-insensitively so "tia  may" doesn't read as a new person.
  def repeat_inquiry_display_name(record_name, inbound_name)
    inbound = inbound_name.to_s.strip
    return record_name if inbound.blank?

    normalize = ->(s) { s.to_s.downcase.gsub(/\s+/, ' ').strip }
    return record_name if normalize.call(inbound) == normalize.call(record_name)
    return inbound if record_name.blank?

    "#{inbound} (matched to existing record: #{record_name})"
  end

  def send_repeat_inquiry_email(record, user, inbound_name: nil, match_type: :lead)
    return unless user.email.present?

    frontend_url = ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'
    name = repeat_inquiry_display_name(matched_record_name(record, match_type), inbound_name)
    noun = match_type.to_s
    path = REPEAT_INQUIRY_PATH.fetch(match_type)
    # An account match leaves the account's own fields untouched, so don't tell
    # the owner we filled anything in.
    filled_in = match_type == :account ? '' : 'We filled in any missing details and '
    body = <<~HTML
      <h2>Repeat Inquiry on Existing #{noun.capitalize}</h2>
      <p>An <strong>existing #{noun}</strong> re-engaged via <strong>#{@source_label}</strong>.
      #{filled_in}logged the new inquiry as a note. No duplicate lead was created.</p>

      <h3>Contact Information</h3>
      <p>
        <strong>Name:</strong> #{name.presence || 'Not provided'}<br>
        <strong>Email:</strong> #{record.try(:email) || 'Not provided'}<br>
        <strong>Phone:</strong> #{record.try(:phone) || 'Not provided'}
      </p>

      <p><a href="#{frontend_url}#{path}/#{record.id}" style="background-color: #3b82f6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 5px; display: inline-block;">View #{noun.capitalize} in CRM</a></p>

      <hr>
      <p style="color: #6b7280; font-size: 12px;">#{@company&.name} - Automated Lead Notification</p>
    HTML

    CommunicationService.send_email(
      communicable: record,
      to: user.email,
      subject: "Repeat Inquiry: #{name.presence || record.try(:email) || record.try(:phone)} - #{@source_label}",
      body: body,
      category: 'system',
      content_type: 'text/html',
      skip_preference_check: true,
      metadata: {
        source: @origin,
        api_key_name: @source_label,
        existing_lead_update: true,
        matched_record_type: match_type.to_s
      }
    )
    Rails.logger.info "[InboundInquiryAbsorber] Sent repeat-inquiry email to #{user.email} for #{match_type} #{record.id}"
  rescue => e
    Rails.logger.error "[InboundInquiryAbsorber] send_repeat_inquiry_email failed for #{match_type} #{record.id}: #{e.class} - #{e.message}"
  end

  # Write the summary to the polymorphic `notes` table, which is the only store
  # the CRM's Notes tab reads. Best-effort: a note failure must never fail an
  # otherwise good dedupe.
  def write_inbound_note!(entity_type, entity_id, content)
    return nil if content.blank? || entity_id.blank?

    Note.create!(
      entity_type: entity_type,
      entity_id: entity_id.to_s,
      content: content,
      created_by_name: "System (#{@source_label})"
    )
  rescue StandardError => e
    Rails.logger.error "[InboundInquiryAbsorber] write_inbound_note! failed for #{entity_type} #{entity_id}: #{e.class}: #{e.message}"
    nil
  end
end
