# frozen_string_literal: true

require 'rails_helper'

# A site made from a template used to keep the template's fake identity in its
# text blocks and page titles: (555) numbers, info@yourdealership.com,
# "123 Dealer Drive", "Your Dealership Name".
RSpec.describe 'Api::V1::Websites template placeholders', type: :request do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', phone: '(303) 555-0142', email: 'sales@summitpark.example',
                    address_line1: '800 Colfax Ave', city: 'Denver', state: 'CO', zip_code: '80202')
  end
  let(:location) { company.locations.create!(name: 'Denver') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  it 'fills the template identity with the dealer details' do
    post '/api/v1/websites',
         params: {
           website: { name: 'Summit', slug: "s-#{SecureRandom.hex(4)}", location_id: location.id,
                      seo_config: { default_title: 'Homes | Your Dealership Name' } },
           template_data: { pages: [{
             title: 'Contact', path: '/contact', order: 0,
             seo: { title: 'Contact | Your Dealership Name' },
             blocks: [{ type: 'text', content: { html: '<p>(555) 123-4567 · info@yourdealership.com</p>' } },
                      { type: 'map', content: { address: '123 Dealer Drive, Your City, ST 12345' } }]
           }] }
         }.to_json,
         headers: headers

    site = Website.find(JSON.parse(response.body)['id'])
    page = site.website_pages.find_by(path: '/contact')

    expect(page.seo_title).to eq('Contact | Summit Park Homes')
    expect(page.blocks[0]['content']['html']).to eq('<p>(303) 555-0142 · sales@summitpark.example</p>')
    expect(page.blocks[1]['content']['address']).to eq('800 Colfax Ave, Denver, CO 80202')
    expect(site.reload.seo_config.to_h.to_json).not_to include('Your Dealership Name')
  end
end
