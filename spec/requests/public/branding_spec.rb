# frozen_string_literal: true

require 'rails_helper'

# A dealer's website sends people to our sign-in, and a page wearing our logo
# reads as having been handed off to a stranger. This is the lookup that lets
# the sign-in look like the place the visitor just left.
RSpec.describe 'Public branding', type: :request do
  let(:company) { create(:company, name: 'Home + Design Studio') }

  it "returns the dealer's own identity" do
    get '/public/branding', params: { company_id: company.id }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('branding', 'name')).to eq('Home + Design Studio')
  end

  it 'needs no credential, since nobody is signed in yet' do
    get '/public/branding', params: { company_id: company.id }

    expect(response).to have_http_status(:ok)
  end

  # The sign-in page must render whatever happens here.
  it 'answers plainly for a company that does not exist' do
    get '/public/branding', params: { company_id: 0 }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['branding']).to be_nil
  end

  it 'answers plainly when asked for nothing at all' do
    get '/public/branding'

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['branding']).to be_nil
  end

  # The reason every embedded sign-in wore our logo instead of the dealer's:
  # resolve_branding_for_inventory fills 'logo', and this read only 'logo_url',
  # so a company with a perfectly good mark answered with a name and nothing
  # else. The old spec asserted the name and never the logo, which is how it
  # survived.
  it 'returns the logo whichever key the branding was written under' do
    %w[logo_url logoUrl logo].each do |key|
      Setting.set('Company', company.id, 'branding', { key => "https://cdn.example.com/#{key}.png" })

      get '/public/branding', params: { company_id: company.id }

      expect(JSON.parse(response.body).dig('branding', 'logo_url'))
        .to eq("https://cdn.example.com/#{key}.png"), "missed the #{key} spelling"
    end
  end

  # A demo wears the scanned prospect's brand, not the lot company's, so asking
  # the tenant would answer with the wrong dealer entirely.
  it 'wears the scanned brand when the visitor is looking at a demo' do
    profile = SiteContentProfile.create!(
      company: company, source_url: 'https://dealer.com', status: 'ready', source_kind: 'url',
      preview_token: SecureRandom.urlsafe_base64(24),
      profile: { 'brand' => { 'name' => 'Sunshine Homes', 'logo_url' => 'https://cdn.example.com/sun.png' } }
    )

    get '/public/branding', params: { company_id: company.id, demo_token: profile.preview_token }

    body = JSON.parse(response.body)['branding']
    expect(body['name']).to eq('Sunshine Homes')
    expect(body['logo_url']).to eq('https://cdn.example.com/sun.png')
  end

  it 'wears the brand of the site the visitor came from' do
    site = company.websites.create!(name: 'Studio', slug: "s-#{SecureRandom.hex(4)}",
                                    location: company.locations.create!(name: 'Lot'),
                                    brand: { 'company_name' => 'Studio Homes',
                                             'logo_url' => 'https://cdn.example.com/studio.png' })

    get '/public/branding', params: { company_id: company.id, website_id: site.id }

    body = JSON.parse(response.body)['branding']
    expect(body['name']).to eq('Studio Homes')
    expect(body['logo_url']).to eq('https://cdn.example.com/studio.png')
  end

  # An id in a query string must not reach another tenant.
  it 'ignores a site belonging to someone else' do
    other = create(:company, name: 'Someone Else')
    theirs = other.websites.create!(name: 'Theirs', slug: "s-#{SecureRandom.hex(4)}",
                                    location: other.locations.create!(name: 'Lot'),
                                    brand: { 'logo_url' => 'https://cdn.example.com/theirs.png' })

    get '/public/branding', params: { company_id: company.id, website_id: theirs.id }

    expect(JSON.parse(response.body).dig('branding', 'logo_url')).not_to eq('https://cdn.example.com/theirs.png')
    expect(JSON.parse(response.body).dig('branding', 'name')).to eq('Home + Design Studio')
  end

  # Deliberately narrow: this cannot become a way to read anything else.
  it 'returns only the name, logo and colour' do
    get '/public/branding', params: { company_id: company.id }

    expect(JSON.parse(response.body)['branding'].keys).to all(be_in(%w[name logo_url primary_color]))
  end
end
