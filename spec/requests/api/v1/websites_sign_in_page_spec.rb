# frozen_string_literal: true

require 'rails_helper'

# Somewhere for the header's Sign In link to land.
#
# Reported from a staging site: clicking Sign In opened our login in a new tab.
# Every design offers the link, so without a page of its own it always left the
# dealer's site , dropping their brand at the moment their client, contractor or
# salesperson was asked to type a password.
RSpec.describe 'Api::V1::Websites sign-in page', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'Denver') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  def create_site(pages)
    post '/api/v1/websites',
         params: { website: { name: 'Sunshine Homes', slug: "s-#{SecureRandom.hex(4)}",
                              location_id: location.id },
                   template_data: { pages: pages } }.to_json,
         headers: auth_headers
    Website.find(JSON.parse(response.body)['id'])
  end

  it 'adds one to a site created from a design' do
    site = create_site([{ title: 'Home', path: '/', order: 0, blocks: [] }])
    page = site.website_pages.find_by(path: '/sign-in')

    expect(page).to be_present
    expect(page.blocks.first['type']).to eq('signIn')
  end

  # The header link is how it is reached; listing it as well would put Sign In
  # in the header twice.
  it 'keeps it out of the navigation' do
    site = create_site([{ title: 'Home', path: '/', order: 0, blocks: [] }])

    expect(site.website_pages.find_by(path: '/sign-in').show_in_nav).to be(false)
  end

  it 'does not add a second one when the design already carries it' do
    site = create_site([
      { title: 'Home', path: '/', order: 0, blocks: [] },
      { title: 'Sign In', path: '/sign-in', order: 1, show_in_nav: false,
        blocks: [{ 'type' => 'signIn', 'order' => 0, 'content' => {} }] }
    ])

    expect(site.website_pages.where(path: '/sign-in').count).to eq(1)
  end
end
