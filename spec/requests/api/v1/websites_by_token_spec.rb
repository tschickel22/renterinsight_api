# frozen_string_literal: true

require 'rails_helper'

# The shareable preview link (/preview/:token). It renders through the same
# SiteRenderer as the published site, so it has to be sent what the published
# site is sent. It was not: every page landed in the header (no show_in_nav),
# a deleted page stayed in the nav, and the contact block had no form to fall
# back to. Found on Coastal Breeze's preview, 2026-11-13.
RSpec.describe 'GET /api/v1/websites/by_token/:token', type: :request do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', public_inventory_token: SecureRandom.hex(16))
  end
  let(:location) { company.locations.create!(name: 'Showroom') }
  let!(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit', slug: "s-#{SecureRandom.hex(4)}", status: 'draft')
  end

  def json
    JSON.parse(response.body)
  end

  def page!(path, **attrs)
    website.website_pages.create!({ title: path, path: path, blocks: [], show_in_nav: true, show_in_footer: true }.merge(attrs))
  end

  it 'says which pages belong in the header and which only in the footer' do
    page!('/about')
    page!('/terms', show_in_nav: false)

    get "/api/v1/websites/by_token/#{website.preview_token}"

    pages = json['website_pages'].index_by { |p| p['path'] }
    expect(pages['/about']['show_in_nav']).to be(true)
    expect(pages['/terms']['show_in_nav']).to be(false)
    expect(pages['/terms']['show_in_footer']).to be(true)
  end

  it 'leaves out deleted pages' do
    page!('/about')
    page!('/home-types', is_deleted: true)

    get "/api/v1/websites/by_token/#{website.preview_token}"

    expect(json['website_pages'].map { |p| p['path'] }).to include('/about')
    expect(json['website_pages'].map { |p| p['path'] }).not_to include('/home-types')
  end

  it "carries the dealer's default contact form" do
    allow(Websites::DefaultLeadForm).to receive(:for).and_return(double(id: 56))

    get "/api/v1/websites/by_token/#{website.preview_token}"

    expect(json['lead_form_id']).to eq(56)
  end
end
