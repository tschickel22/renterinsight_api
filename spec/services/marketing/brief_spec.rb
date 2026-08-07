# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::Brief do
  let(:company) { Company.create!(name: "Brief-#{SecureRandom.hex(4)}") }

  # One brief, many generators. Campaign Desk's premise is that the email, SMS,
  # social post and landing page come from the same instruction — otherwise the
  # landing page argues with the email that drove traffic to it.
  it 'carries the same instruction to every generator' do
    brief = described_class.new(company: company, prompt: 'Spring sale', offer: '$0 down',
                                audience: 'first-time buyers', tone: 'warm')

    payload = brief.to_h_for_prompt
    expect(payload[:prompt]).to eq('Spring sale')
    expect(payload[:offer]).to eq('$0 down')
    expect(payload[:audience]).to eq('first-time buyers')
    expect(payload[:tone]).to eq('warm')
  end

  it 'omits keys it has no value for rather than sending nulls' do
    payload = described_class.new(company: company, prompt: 'x').to_h_for_prompt
    expect(payload).not_to have_key(:offer)
    expect(payload).not_to have_key(:tone)
  end

  describe 'grounding' do
    let(:record) do
      SiteContentProfile.create!(
        company: company, source_url: 'https://example.com', status: 'ready',
        profile: {
          'brand' => { 'name' => 'Real Dealer' },
          'contact' => { 'phone' => '303-555-0100' },
          'copy' => { 'hero' => [{ 'headline' => 'Welcome' }] },
          'links' => { 'internal' => [{ 'path' => '/a' }] },
          'integrations' => [{ 'vendor' => 'thing' }]
        }
      )
    end

    # A full profile is mostly link inventory and vendor detections, which
    # would crowd the copy out of the prompt.
    it 'exposes only what a writer would use' do
      grounding = described_class.new(company: company, site_content_profile: record).grounding

      expect(grounding.keys).to contain_exactly('brand', 'contact', 'copy')
      expect(grounding).not_to have_key('links')
      expect(grounding).not_to have_key('integrations')
    end

    it 'is empty without a profile' do
      expect(described_class.new(company: company).grounding).to eq({})
    end

    it 'prefers the scanned brand name over the company record' do
      expect(described_class.new(company: company, site_content_profile: record).brand_name)
        .to eq('Real Dealer')
    end

    it 'falls back to the company name' do
      expect(described_class.new(company: company).brand_name).to eq(company.name)
    end
  end
end
