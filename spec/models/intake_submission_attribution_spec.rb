# frozen_string_literal: true

require 'rails_helper'

# Regression: a lead created from a paid-ad intake form carried no UTMs, so
# AdCampaign#matched_leads_scope (utm_campaign / utm_content) could never
# attribute it. Every ad driving traffic to an intake form reported 0 leads,
# $0 cost-per-lead and -100% ROI no matter how many leads it actually produced.
RSpec.describe IntakeSubmission, 'campaign attribution' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Main') }
  let!(:form) do
    company.intake_forms.create!(name: 'Demo Request', auto_create_lead: true,
                                 location_id: location.id)
  end

  def submit(payload)
    IntakeSubmission.create!(intake_form: form, payload: payload)
  end

  it 'carries UTMs from the landing URL onto the lead' do
    submission = submit(
      'first_name' => 'Dana', 'last_name' => 'Reed', 'email' => 'dana@example.com',
      'utm_source' => 'facebook', 'utm_medium' => 'paid_social',
      'utm_campaign' => 'RI: One Platform - 2026-07-28', 'utm_content' => '6789'
    )

    lead = submission.reload.lead
    expect(lead).to be_present
    expect(lead.utm_source).to eq('facebook')
    expect(lead.utm_campaign).to eq('RI: One Platform - 2026-07-28')
    expect(lead.utm_content).to eq('6789')
  end

  it 'accepts camelCase keys as well' do
    submission = submit(
      'first_name' => 'Dana', 'email' => 'dana2@example.com',
      'utmCampaign' => 'Spring Push', 'utmContent' => '4242'
    )

    lead = submission.reload.lead
    expect(lead.utm_campaign).to eq('Spring Push')
    expect(lead.utm_content).to eq('4242')
  end

  it 'leaves UTMs blank for an organic submission rather than inventing them' do
    submission = submit('first_name' => 'Dana', 'email' => 'dana3@example.com')

    lead = submission.reload.lead
    expect(lead.utm_campaign).to be_blank
    expect(lead.utm_content).to be_blank
  end

  # The end the whole chain exists for: the campaign can now find its leads.
  it 'lets the ad campaign attribute the lead it paid for' do
    campaign = company.ad_campaigns.create!(
      external_campaign_id: '6789', name: 'RI: One Platform - 2026-07-28',
      status: 'ACTIVE', spend: 50.0, ad_account_id: '111'
    )

    submit('first_name' => 'Dana', 'email' => 'dana4@example.com',
           'utm_campaign' => 'RI: One Platform - 2026-07-28', 'utm_content' => '6789')

    campaign.calculate_roi!

    expect(campaign.leads_count).to eq(1)
    expect(campaign.cost_per_lead).to eq(50.0)
  end
end
