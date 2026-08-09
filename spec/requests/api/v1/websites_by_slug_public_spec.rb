# frozen_string_literal: true

require 'rails_helper'

# The draft preview at /s/:slug. It renders through the same SiteRenderer as the
# published site, so what it is sent has to match what the published site is
# sent. A preview that renders differently from the live site is worse than no
# preview, because it is where a dealer checks their work.
RSpec.describe 'GET /api/v1/websites/by_slug_public/:slug', type: :request do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', public_inventory_token: SecureRandom.hex(16))
  end
  let(:location) { company.locations.create!(name: 'Showroom') }
  let!(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published')
  end

  def json
    JSON.parse(response.body)
  end

  # Measured in a browser: the assistant a dealer pays for was invisible on
  # their own preview, because this payload never said whether they had it.
  it 'says whether the dealer has the assistant' do
    allow_any_instance_of(ModuleAccessService).to receive(:module_enabled?).and_return(true)

    get "/api/v1/websites/by_slug_public/#{website.slug}"

    expect(response).to have_http_status(:ok)
    expect(json['concierge_enabled']).to be(true)
  end

  it 'says so plainly when they do not' do
    allow_any_instance_of(ModuleAccessService).to receive(:module_enabled?).and_return(false)

    get "/api/v1/websites/by_slug_public/#{website.slug}"

    expect(json['concierge_enabled']).to be(false)
  end

  it 'still answers when the module check itself fails' do
    allow_any_instance_of(ModuleAccessService).to receive(:module_enabled?).and_raise('boom')

    get "/api/v1/websites/by_slug_public/#{website.slug}"

    expect(response).to have_http_status(:ok)
    expect(json['concierge_enabled']).to be(false)
  end

  it 'carries the token the assistant and the listing grid both need' do
    get "/api/v1/websites/by_slug_public/#{website.slug}"

    expect(json.dig('inventory_embed_config', 'token')).to eq(company.public_inventory_token)
  end
end
