# frozen_string_literal: true

require 'rails_helper'

# A design names the kind of place its site describes (The James is an
# ApartmentComplex). The create call carried it in seo_config and the API
# dropped it, so the markup fell back to the industry's generic type.
RSpec.describe 'Website business type', type: :request do
  let(:company) { Company.create!(name: 'The James Apts', industry: 'property_management') }
  let!(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:platform) do
    User.create!(email: "p#{SecureRandom.hex(3)}@james.example", first_name: 'P', last_name: 'A', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin', status: 'active')
  end

  def create_site(seo)
    post '/api/v1/websites',
         params: { website: { name: 'The James', slug: "s-#{SecureRandom.hex(4)}", status: 'draft', location_id: location.id,
                              seo_config: seo } }.to_json,
         headers: { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(platform)}",
                    'Content-Type' => 'application/json', 'X-Company-ID' => company.id.to_s }
  end

  it 'keeps the business type a design sends' do
    create_site(default_title: 'The James Apartments', business_type: 'ApartmentComplex')

    expect(response).to have_http_status(:created).or have_http_status(:ok)
    site = company.websites.order(:id).last
    expect(site.seo_config).to include('default_title' => 'The James Apartments', 'business_type' => 'ApartmentComplex')

    graph = Websites::StructuredData.new(website: site, page: nil, canonical_host: 'jamesapts.com').graph
    expect(graph.map { |n| n['@type'] }).to include('WebSite')
    expect(Websites::StructuredData.new(website: site, page: nil, canonical_host: 'x').send(:business_type)).to eq('ApartmentComplex')
  end
end
