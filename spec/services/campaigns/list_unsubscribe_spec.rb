# frozen_string_literal: true

require 'rails_helper'

# RFC 8058 one-click unsubscribe. Gmail has required it of bulk senders since
# 2024, and it puts Gmail's own unsubscribe control beside the sender name
# instead of making the recipient hunt for the footer link.
RSpec.describe 'Campaign List-Unsubscribe headers' do
  # A real campaign recipient ticked the consent box on a lead form, so these
  # fixtures carry the consent that Campaigns::CampaignSender now requires.
  before do
    CommunicationPreferenceService.opt_in(recipient: lead, channel: 'email', category: 'marketing',
                                          ip_address: '203.0.113.10', user_agent: 'RSpec')
  end

  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead) do
    Lead.create!(company: company, source: source, owner_id: rep.id, first_name: 'Sam', last_name: 'K',
                 email: 'sam@example.com')
  end

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: rep.id, name: 'Weekly homes',
                         campaign_type: 'blast', channel: 'email', from_identity_type: 'Owner',
                         throttle_per_day: 100, email_waterfall: true)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'Hi' }])
    c
  end

  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email, status: 'pending')
  end

  before do
    allow(CommunicationService).to receive(:send_email).and_return(
      { success: true, communication: instance_double(Communication, id: 999, body: '<p>x</p>', update_column: true) }
    )
  end

  it 'carries both headers, pointing at the same signed token as the footer link' do
    Campaigns::CampaignSender.new(enrollment: enrollment).deliver_current_step

    expect(CommunicationService).to have_received(:send_email) do |args|
      headers = args[:extra_headers]
      expect(headers['List-Unsubscribe-Post']).to eq('List-Unsubscribe=One-Click')
      expect(headers['List-Unsubscribe']).to match(%r{\A<https?://.+/u/.+>\z})
      expect(headers['List-Unsubscribe']).not_to include('/u/preview')
    end
  end

  describe 'the mailer' do
    it 'writes arbitrary headers onto the message' do
      mail = CommunicationMailer.send_communication(
        to: 'sam@example.com', subject: 'Hi', body: '<p>Hi</p>',
        from_email: 'rep@dealer.example', from_name: 'Rita',
        extra_headers: { 'List-Unsubscribe' => '<https://api.example.com/u/tok>',
                         'List-Unsubscribe-Post' => 'List-Unsubscribe=One-Click' }
      )

      expect(mail['List-Unsubscribe'].to_s).to eq('<https://api.example.com/u/tok>')
      expect(mail['List-Unsubscribe-Post'].to_s).to eq('List-Unsubscribe=One-Click')
    end

    it 'is unchanged when no headers are given' do
      mail = CommunicationMailer.send_communication(
        to: 'sam@example.com', subject: 'Hi', body: '<p>Hi</p>',
        from_email: 'rep@dealer.example', from_name: 'Rita'
      )

      expect(mail['List-Unsubscribe']).to be_nil
    end
  end

  describe 'a preview render' do
    it 'gets no header rather than one pointing at /u/preview' do
      sender = Campaigns::CampaignSender.new(enrollment: enrollment)
      headers = sender.send(:unsubscribe_headers, 'https://api.example.com/u/preview')

      expect(headers).to eq({})
    end
  end
end
