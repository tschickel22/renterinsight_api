# frozen_string_literal: true

require 'rails_helper'

# Suppression answers "did they opt out". This answers "did they ever opt in",
# which is the question Google asked and the one an opt-out-only system cannot
# answer. Before this, a contact who had never agreed to anything was mailable
# as long as they had not previously unsubscribed.
RSpec.describe Campaigns::CampaignSender, 'marketing consent gate' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead) do
    Lead.create!(company: company, source: source, owner_id: rep.id, first_name: 'Sam', last_name: 'K',
                 email: 'sam@example.com')
  end

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: rep.id, name: 'Weekly',
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
      { success: true, communication: instance_double(Communication, id: 1, body: '<p>x</p>', update_column: true) }
    )
  end

  def consent!
    CommunicationPreferenceService.opt_in(recipient: lead, channel: 'email', category: 'marketing',
                                          ip_address: '203.0.113.9', user_agent: 'Mozilla/5.0')
  end

  it 'will not mail a contact who never agreed to anything' do
    described_class.new(enrollment: enrollment).deliver_current_step

    expect(CommunicationService).not_to have_received(:send_email)
  end

  it 'mails a contact who did agree' do
    consent!

    expect(described_class.new(enrollment: enrollment).deliver_current_step).to be true
    expect(CommunicationService).to have_received(:send_email)
  end

  it 'treats an absent tenant setting as the gate being on' do
    expect(Setting.get('Company', company.id, 'require_marketing_consent')).to be_nil

    described_class.new(enrollment: enrollment).deliver_current_step

    expect(CommunicationService).not_to have_received(:send_email)
  end

  it 'lets a tenant mid-migration opt out of the gate deliberately' do
    Setting.set('Company', company.id, 'require_marketing_consent', false)

    expect(described_class.new(enrollment: enrollment).deliver_current_step).to be true
    expect(CommunicationService).to have_received(:send_email)
  end

  it 'does not count an opt-out as consent' do
    consent!
    CommunicationPreferenceService.opt_out(recipient: lead, channel: 'email', category: 'marketing')

    described_class.new(enrollment: enrollment).deliver_current_step

    expect(CommunicationService).not_to have_received(:send_email)
  end

  it 'does not accept a transactional preference as marketing consent' do
    CommunicationPreferenceService.opt_in(recipient: lead, channel: 'email', category: 'transactional')

    described_class.new(enrollment: enrollment).deliver_current_step

    expect(CommunicationService).not_to have_received(:send_email)
  end
end
