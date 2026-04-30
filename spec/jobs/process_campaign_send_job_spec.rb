# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProcessCampaignSendJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead)    { Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@b.com') }
  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                         campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                         throttle_per_day: 100, status: 'running')
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi', body_blocks: [{ 'type' => 'text', 'html' => 'x' }])
    c
  end

  it 'invokes CampaignSender for active enrollments' do
    enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                                             recipient_type: 'Lead', recipient_id: lead.id,
                                             email_address_snapshot: lead.email, status: 'active',
                                             next_send_at: 1.minute.ago)
    sender = instance_double(Campaigns::CampaignSender, deliver_current_step: true)
    allow(Campaigns::CampaignSender).to receive(:new).and_return(sender)
    described_class.perform_now(enrollment.id)
    expect(sender).to have_received(:deliver_current_step)
  end

  it 'no-ops for completed enrollments' do
    enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                                             recipient_type: 'Lead', recipient_id: lead.id,
                                             email_address_snapshot: lead.email, status: 'completed')
    expect(Campaigns::CampaignSender).not_to receive(:new)
    described_class.perform_now(enrollment.id)
  end
end
