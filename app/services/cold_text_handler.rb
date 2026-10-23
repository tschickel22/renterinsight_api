# frozen_string_literal: true

# A text to a dealer's own or provisioned number that is not a reply to
# anything they sent (Webhooks::TwilioController#sms_inbound). Someone already
# in the CRM by that phone gets it on their conversation, and their owner and
# followers are told. Anyone else becomes a new lead, owned per the dealer's
# UnmatchedTextRouting setting; with nobody set, it is left unassigned at the
# dealer's inbound location and their admins are told.
#
# Opt-out and opt-in keywords never come here: those are handled before, and a
# STOP is not an enquiry.
class ColdTextHandler
  SOURCE_NAME = 'Text message'

  Result = Struct.new(:communication, :record, :created_lead, keyword_init: true)

  def initialize(company:, twilio_account:, from:, to:, body:, message_sid:)
    @company = company
    @twilio_account = twilio_account
    @from = from
    @to = to
    @body = body
    @message_sid = message_sid
  end

  def call
    match = IdentityResolver.new(@company, phone: @from).resolve
    record = match&.record
    created = false
    unless record
      record = create_lead!
      created = true
    end

    comm = Communication.create!(
      company_id: @company.id, communicable: record, channel: 'sms', direction: 'inbound',
      from_address: @from, to_address: @to, body: @body, status: 'delivered',
      sent_at: Time.current, delivered_at: Time.current,
      metadata: { 'message_sid' => @message_sid, 'cold_text' => true, 'created_lead' => created,
                  'source' => 'dedicated' }.compact
    )
    SmsUsageLog.log!(company: @company, direction: 'inbound', source: 'inbound', communication_id: comm.id)
    notify(record, comm, created)
    Result.new(communication: comm, record: record, created_lead: created)
  end

  private

  def create_lead!
    routing = UnmatchedTextRouting.new(@company)
    source = SourceResolverService.resolve(company: @company, source_name: SOURCE_NAME)
    @company.leads.create!(
      first_name: "Text from", last_name: pretty_phone, phone: @from, status: 'new', origin: Lead::ORIGIN_SMS,
      source_id: source&.id, owner_id: routing.next_owner_id,
      location_id: @twilio_account&.location_id || @company.inbound_lead_location&.id,
      notes: "First contact by text to #{@to}: #{@body}"
    )
  end

  def notify(record, comm, created)
    label = record.try(:full_name).presence || record.try(:name).presence || pretty_phone
    recipients = record.respond_to?(:notify_audience) ? record.notify_audience(except: nil) : []
    if created && recipients.empty?
      # Nobody owns it: the people who can set the routing hear about it.
      recipients = @company.users.where(status: 'active').select(&:effective_admin?)
    end
    message = created ? "New lead by text from #{pretty_phone}: #{@body.to_s.truncate(120)}" :
                        "Text from #{label}: #{@body.to_s.truncate(120)}"
    recipients.each do |user|
      NotificationService.create(
        recipient: user, notification_type: created ? :sms_new_lead : :sms_reply_received,
        notifiable: created ? record : comm, message: message, company_id: @company.id,
        action_text: created ? 'View Lead' : 'View Conversation'
      )
    end
  rescue StandardError => e
    Rails.logger.error "[ColdTextHandler] notify failed for #{record.class.name} #{record.id}: #{e.class}: #{e.message}"
  end

  def pretty_phone
    d = @from.to_s.gsub(/\D/, '').last(10)
    d.length == 10 ? "(#{d[0, 3]}) #{d[3, 3]}-#{d[6, 4]}" : @from.to_s
  end
end
