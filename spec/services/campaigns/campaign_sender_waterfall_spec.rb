# frozen_string_literal: true

require 'rails_helper'

# A campaign with email_waterfall never skips a recipient for want of a mailbox.
RSpec.describe Campaigns::CampaignSender, 'email waterfall' do
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
    Lead.create!(company: company, source: source, owner_id: rep.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com')
  end

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: rep.id, name: 'Weekly homes', campaign_type: 'blast',
                         channel: 'email', from_identity_type: 'Owner', throttle_per_day: 100, email_waterfall: true)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi {{first_name}}',
                             body_blocks: [{ 'type' => 'text', 'html' => 'Hi {{first_name}}' }])
    c
  end

  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: lead.email, status: 'pending')
  end

  before do
    allow(CommunicationService).to receive(:send_email).and_return(
      { success: true, communication: instance_double(Communication, id: 999, body: '<p>x</p>', update_column: true) }
    )
  end

  it "sends from the location, company or platform settings when the rep has no mailbox" do
    expect(described_class.new(enrollment: enrollment).deliver_current_step).to be true

    # No from and no provider: CommunicationService takes both from the settings waterfall.
    expect(CommunicationService).to have_received(:send_email)
      .with(hash_including(communicable: lead, from: nil, provider: nil, sender_user_id: rep.id))
    send = CampaignSend.find_by(campaign_enrollment_id: enrollment.id)
    expect(send.sent_at).to be_present
    expect(send.sending_connection_key).to eq(lead.location_id ? "EmailWaterfall:location:#{lead.location_id}" : "EmailWaterfall:company:#{company.id}")
  end

  it "uses the rep's own mailbox when there is one" do
    UserEmailConnection.create!(user_id: rep.id, company_id: company.id, provider: 'oauth_outlook', is_active: true,
                                email_address: rep.email, display_name: 'Rita Rep')

    expect(described_class.new(enrollment: enrollment).deliver_current_step).to be true
    expect(CommunicationService).to have_received(:send_email).with(hash_including(from: rep.email, provider: :oauth_microsoft))
  end

  it 'still fails a recipient with no mailbox when the campaign has no waterfall' do
    campaign.update!(email_waterfall: false)

    expect(described_class.new(enrollment: enrollment).deliver_current_step).to be false
    expect(enrollment.reload).to have_attributes(status: 'failed', failure_reason: 'no_valid_email_connection')
    expect(CommunicationService).not_to have_received(:send_email)
  end

  it 'lets a waterfall campaign start without any connected mailbox' do
    company_campaign = Campaign.create!(company_id: company.id, created_by_user_id: rep.id, name: 'Company send', campaign_type: 'blast',
                                        channel: 'email', from_identity_type: 'Company', from_identity_id: company.id,
                                        throttle_per_day: 100, status: 'draft', email_waterfall: true)
    company_campaign.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi', body_blocks: [])
    company_campaign.create_campaign_audience!(source_type: 'Lead', filter_tree: {})

    expect(company_campaign.can_start?).to be true
    company_campaign.update!(email_waterfall: false)
    expect(company_campaign.reload.can_start?).to be false
  end
end
