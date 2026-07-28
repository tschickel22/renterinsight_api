# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AdCampaign, 'attribution' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def lead_at(time, attrs = {})
    company.leads.create!(
      { first_name: 'L', last_name: SecureRandom.hex(3), email: "l-#{SecureRandom.hex(4)}@example.com",
        created_at: time }.merge(attrs)
    )
  end

  # Regression: matched_leads_scope had no time bound, so a campaign that
  # stopped a year ago kept claiming every new lead whose utm_campaign still
  # matched its name — inflating its ROI indefinitely.
  describe 'the attribution window' do
    let(:campaign) do
      company.ad_campaigns.create!(
        external_campaign_id: 'c1', name: 'Spring Push', status: 'PAUSED', spend: 100,
        started_at: Time.utc(2026, 4, 1), stopped_at: Time.utc(2026, 4, 8)
      )
    end

    it 'counts a lead that arrived while the campaign ran' do
      lead_at(Time.utc(2026, 4, 4), utm_content: 'c1')

      campaign.calculate_roi!
      expect(campaign.leads_count).to eq(1)
    end

    # A click can precede the form fill by weeks in a housing purchase.
    it 'counts a lead inside the tail after the campaign stopped' do
      lead_at(Time.utc(2026, 4, 25), utm_content: 'c1')

      campaign.calculate_roi!
      expect(campaign.leads_count).to eq(1)
    end

    it 'ignores a lead long after the campaign stopped' do
      lead_at(Time.utc(2026, 7, 1), utm_content: 'c1')

      campaign.calculate_roi!
      expect(campaign.leads_count).to eq(0)
    end

    it 'ignores a lead that predates the campaign' do
      lead_at(Time.utc(2026, 1, 1), utm_content: 'c1')

      campaign.calculate_roi!
      expect(campaign.leads_count).to eq(0)
    end

    it 'runs to now for a campaign with no stop date' do
      campaign.update!(stopped_at: nil)
      lead_at(Time.current, utm_content: 'c1')

      campaign.calculate_roi!
      expect(campaign.leads_count).to eq(1)
    end

    # Rows predating the columns must not silently drop to zero leads.
    it 'stays unbounded when Meta gave us no start date' do
      campaign.update!(started_at: nil, stopped_at: nil)
      lead_at(Time.utc(2020, 1, 1), utm_content: 'c1')

      campaign.calculate_roi!
      expect(campaign.leads_count).to eq(1)
    end
  end

  # Counting these toward a campaign would let every campaign claim the same
  # leads; the point is to make a broken UTM chain visible, not to attribute.
  describe '.unattributed_facebook_leads' do
    let!(:campaign) do
      company.ad_campaigns.create!(external_campaign_id: 'c1', name: 'Spring Push', status: 'ACTIVE')
    end

    it 'counts a Facebook lead no campaign matched' do
      lead_at(Time.current, utm_source: 'facebook')

      expect(described_class.unattributed_facebook_leads(company).count).to eq(1)
    end

    it 'excludes a lead a campaign already claims by id' do
      lead_at(Time.current, utm_source: 'facebook', utm_content: 'c1')

      expect(described_class.unattributed_facebook_leads(company).count).to eq(0)
    end

    it 'excludes a lead a campaign already claims by name' do
      lead_at(Time.current, utm_source: 'facebook', utm_campaign: 'Spring Push')

      expect(described_class.unattributed_facebook_leads(company).count).to eq(0)
    end

    it 'ignores leads that did not come from Facebook' do
      lead_at(Time.current, utm_source: 'google')

      expect(described_class.unattributed_facebook_leads(company).count).to eq(0)
    end

    it 'recognises a Facebook lead by its source record' do
      source = company.sources.create!(name: 'Facebook Ads', source_type: 'paid_ad', is_active: true)
      lead_at(Time.current, source_id: source.id)

      expect(described_class.unattributed_facebook_leads(company).count).to eq(1)
    end

    it 'counts a Facebook lead whose UTMs are missing entirely' do
      lead_at(Time.current, utm_source: 'Facebook', utm_campaign: nil, utm_content: nil)

      expect(described_class.unattributed_facebook_leads(company).count).to eq(1)
    end
  end
end
