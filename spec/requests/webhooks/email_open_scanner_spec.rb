# frozen_string_literal: true

require 'rails_helper'

# Mail scanners load the tracking picture on arrival; they must not count as
# the person reading the email (ScannerOpen, 2026-11-09).
RSpec.describe 'Email opens from mail scanners', type: :request do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead) { Lead.create!(company: company, source: source, first_name: 'B', last_name: '1', email: "b-#{SecureRandom.hex(4)}@gmail.com") }
  let(:communication) do
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
                          subject: 'S', body: 'B', from_address: 'sender@example.com',
                          to_address: lead.email, status: 'sent', sent_at: 5.seconds.ago)
  end
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C', campaign_type: 'blast',
                     from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ 'type' => 'text', 'html' => 'x' }]) }
  let(:enr) { CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead', recipient_id: lead.id, email_address_snapshot: lead.email) }
  let!(:send_row) do
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: enr.id, communication_id: communication.id)
  end

  gmail_scanner = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.135 Safari/537.36 Edge/12.246 Mozilla/5.0'
  gmail_person = 'Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko Firefox/11.0 (via ggpht.com GoogleImageProxy)'
  desktop = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36'

  def open_pixel(ua)
    get "/webhooks/email/#{communication.id}/pixel.gif", headers: { 'User-Agent' => ua }
  end

  it "keeps Gmail's scanner as a scanner look, not an open" do
    open_pixel(gmail_scanner)
    expect(response.media_type).to eq('image/gif')
    expect(communication.reload.read_at).to be_nil
    expect(communication.communication_events.pluck(:event_type)).to eq(['scanner_open'])
    expect(send_row.reload.opened_at).to be_nil
    expect(send_row.open_count).to eq(0)
  end

  it 'treats a desktop browser in the first minute as a scanner' do
    open_pixel(desktop)
    expect(communication.reload.read_at).to be_nil
  end

  it 'counts a person reading in Gmail, even straight away' do
    open_pixel(gmail_scanner)
    open_pixel(gmail_person)
    expect(communication.reload.read_at).to be_present
    expect(communication.communication_events.opened.count).to eq(1)
    expect(send_row.reload.open_count).to eq(1)
  end

  it 'counts a desktop browser after the first minute' do
    communication.update_column(:sent_at, 10.minutes.ago)
    open_pixel(desktop)
    expect(communication.reload.read_at).to be_present
  end

  describe 'ScannerOpen.reclassify!' do
    it 'clears read and campaign opens that were only scanners, keeping real ones' do
      sent = communication.sent_at
      communication.update_column(:read_at, sent + 3.seconds)
      CommunicationEvent.create!(communication: communication, event_type: 'opened', occurred_at: sent + 3.seconds, user_agent: gmail_scanner)
      send_row.update_columns(opened_at: sent + 3.seconds, open_count: 1)

      other = Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
                                    subject: 'S2', body: 'B', from_address: 'sender@example.com', to_address: lead.email,
                                    status: 'sent', sent_at: 2.hours.ago, read_at: 1.hour.ago)
      CommunicationEvent.create!(communication: other, event_type: 'opened', occurred_at: 2.hours.ago + 4.seconds, user_agent: desktop)
      real = CommunicationEvent.create!(communication: other, event_type: 'opened', occurred_at: 1.hour.ago, user_agent: gmail_person)

      result = ScannerOpen.reclassify!

      expect(result[:events]).to eq(2)
      expect(communication.reload.read_at).to be_nil
      expect(send_row.reload.opened_at).to be_nil
      expect(send_row.open_count).to eq(0)
      expect(other.reload.read_at).to be_within(1.second).of(real.occurred_at)
      expect(other.communication_events.opened.pluck(:id)).to eq([real.id])
    end

    it 'keeps the open on a campaign send that was clicked' do
      sent = communication.sent_at
      CommunicationEvent.create!(communication: communication, event_type: 'opened', occurred_at: sent + 3.seconds, user_agent: gmail_scanner)
      send_row.update_columns(opened_at: sent + 3.seconds, open_count: 1, clicked_at: sent + 1.minute)

      ScannerOpen.reclassify!

      expect(send_row.reload.opened_at).to be_present
      expect(send_row.open_count).to eq(1)
    end
  end
end
