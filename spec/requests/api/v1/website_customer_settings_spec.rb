# frozen_string_literal: true

require 'rails_helper'

# Customers get the website settings page without SEO or custom code, and the
# page sends everything it holds on save, so the API has to protect them too.
RSpec.describe 'Saving website settings as a customer', type: :request do
  let(:company) { Company.create!(name: 'Save Homes', address_line1: '1 Lot', city: 'Denver', state: 'CO', zip_code: '80231') }
  let(:location) { company.locations.first || company.locations.create!(name: 'Lot') }
  let(:level) { 1 }
  let!(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Original', slug: "s-#{SecureRandom.hex(4)}", status: 'draft',
                    client_access_level: level, seo_config: { 'default_title' => 'Our title' },
                    tracking_config: { 'google_ads_id' => 'AW-123456', 'custom_scripts' => { 'head' => '<script>ours()</script>' } })
  end
  let(:person) do
    User.create!(email: "c#{SecureRandom.hex(2)}@save.example", first_name: 'A', last_name: 'B', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:platform) do
    User.create!(email: "p#{SecureRandom.hex(2)}@save.example", first_name: 'P', last_name: 'A', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin', status: 'active')
  end

  def save(user, attrs)
    patch "/api/v1/websites/#{website.id}", params: { website: attrs }.to_json, headers: {
      'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json', 'X-Company-ID' => company.id.to_s
    }
    website.reload
  end

  let(:whole_form) do
    { name: 'Changed', status: 'published', theme: { primary_color: '#000000' },
      seo_config: { default_title: 'Hacked title' },
      tracking_config: { google_analytics_id: 'G-ABC12345', google_ads_id: 'AW-123456', custom_scripts: { head: '<script>evil()</script>' } } }
  end

  context 'on a managed site' do
    it 'saves the tracking id and nothing else from the form' do
      save(person, whole_form)

      expect(response).to have_http_status(:ok)
      expect(website.tracking_config['google_analytics_id']).to eq('G-ABC12345')
      expect(website.name).to eq('Original')
      expect(website.status).to eq('draft')
      expect(website.seo_config['default_title']).to eq('Our title')
    end

    it 'keeps the saved custom code rather than replacing or wiping it' do
      save(person, whole_form)
      expect(website.tracking_config.dig('custom_scripts', 'head')).to eq('<script>ours()</script>')

      save(person, tracking_config: { google_analytics_id: 'G-ABC12345' })
      expect(website.tracking_config.dig('custom_scripts', 'head')).to eq('<script>ours()</script>')
    end
  end

  context 'on a full editor site' do
    let(:level) { 3 }

    it 'saves their settings, but still not SEO or custom code' do
      save(person, whole_form)

      expect(website.name).to eq('Changed')
      expect(website.seo_config['default_title']).to eq('Our title')
      expect(website.tracking_config.dig('custom_scripts', 'head')).to eq('<script>ours()</script>')
    end
  end

  it 'still lets the platform team change everything' do
    save(platform, whole_form)

    expect(website.name).to eq('Changed')
    expect(website.seo_config['default_title']).to eq('Hacked title')
    expect(website.tracking_config.dig('custom_scripts', 'head')).to eq('<script>evil()</script>')
  end
end
