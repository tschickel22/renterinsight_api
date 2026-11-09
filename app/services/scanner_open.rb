# frozen_string_literal: true

# Mail scanners load an email's tracking picture the moment it arrives, before
# the person sees it, so a scanner looked like the buyer reading the email.
# Measured on production 2026-11-09 (first opens since the visitor's own
# address was recorded, 2026-11-05):
#   - Gmail's incoming-mail scanner: an old Chrome/Edge signature from Google
#     addresses, 198 of 208 within 10 seconds of sending, never a real open.
#     A person reading in Gmail shows as GoogleImageProxy instead.
#   - Microsoft 365 and other company scanners: desktop Chrome from data
#     centres, all within 2 minutes and nearly all within 30 seconds.
# People's opens through Gmail, Yahoo, Apple Mail, Outlook or a phone keep
# counting, even quickly. Campaigns::ScannerClick does the same for links.
module ScannerOpen
  # Gmail's scanner, whatever the timing.
  GMAIL_SCANNER = /Edge\/12\.246 Mozilla\/5\.0\z/
  # A first look this soon after sending, from a plain desktop browser, is a
  # scanner. Measured scanners all landed inside it; people barely do.
  QUICK = 60.seconds
  # Clients a person reads mail in. Their opens always count.
  PERSON = /GoogleImageProxy|YahooMailProxy|iPhone|iPad|Android|Microsoft Outlook|Microsoft Office|Thunderbird|Macintosh/i

  def self.scanner?(user_agent:, sent_at:, at: Time.current)
    ua = user_agent.to_s
    return true if ua.match?(GMAIL_SCANNER)
    return false if ua.match?(PERSON)
    return false if sent_at.blank?

    at - sent_at < QUICK
  end

  # Opens already recorded that were scanners: moved to 'scanner_open' so they
  # stop counting, then read_at and the campaign open columns are worked out
  # again from the opens left. A send with a click keeps its open (a click
  # means a person had it open). Returns the counts it changed.
  def self.reclassify!(events = CommunicationEvent.where(event_type: 'opened'))
    ids = scanner_event_ids(events)
    return { events: 0, communications: 0, campaign_sends: 0 } if ids.empty?

    comm_ids = CommunicationEvent.where(id: ids).distinct.pluck(:communication_id)
    CommunicationEvent.where(id: ids).update_all(event_type: 'scanner_open', updated_at: Time.current)
    comms = 0
    sends = 0
    comm_ids.each_slice(500) do |slice|
      first_open = CommunicationEvent.where(communication_id: slice, event_type: 'opened')
                                     .group(:communication_id).minimum(:occurred_at)
      opens = CommunicationEvent.where(communication_id: slice, event_type: 'opened').group(:communication_id).count
      Communication.where(id: slice).find_each do |c|
        next if c.read_at == first_open[c.id]

        c.update_column(:read_at, first_open[c.id])
        comms += 1
      end
      CampaignSend.where(communication_id: slice).find_each do |s|
        count = opens[s.communication_id].to_i
        count = [count, 1].max if s.clicked_at.present?
        opened_at = first_open[s.communication_id] || (s.clicked_at.present? ? s.opened_at : nil)
        next if s.open_count == count && s.opened_at == opened_at

        s.update_columns(open_count: count, opened_at: opened_at)
        sends += 1
      end
    end
    { events: ids.size, communications: comms, campaign_sends: sends }
  end

  # The recorded opens in events that were scanners.
  def self.scanner_event_ids(events = CommunicationEvent.where(event_type: 'opened'))
    ids = []
    events.where(event_type: 'opened').joins(:communication)
          .select('communication_events.id, communication_events.user_agent, communication_events.occurred_at, communications.sent_at AS comm_sent_at')
          .find_each do |e|
      ids << e.id if scanner?(user_agent: e.user_agent, sent_at: e['comm_sent_at'], at: e.occurred_at)
    end
    ids
  end
end
