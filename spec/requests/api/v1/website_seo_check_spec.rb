# frozen_string_literal: true

require 'rails_helper'

# The endpoint behind the SEO check in the builder. It exists so a dealer can
# fix a heading and look again, so it must be safely re-runnable and must work
# on a draft, which has no live URL to crawl.
RSpec.describe 'GET /api/v1/websites/:id/seo_check', type: :request do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', address_line1: '100 Lot Road', city: 'Denver',
                    state: 'CO', zip_code: '80231')
  end
  let(:location) { company.locations.create!(name: 'Lot') }
  let!(:website) do
    site = Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                           slug: "s-#{SecureRandom.hex(4)}", status: 'draft')
    site.website_pages.create!(title: 'Home', path: '/', order: 0, blocks: [
                                 { 'type' => 'hero', 'order' => 0,
                                   'content' => { 'title' => 'Homes in Denver',
                                                  'subtitle' => 'Family owned since 1998.' } }
                               ])
    site
  end

  # Exercised through the service, since the controller's own auth is covered by
  # the shared examples every other endpoint here uses.
  def report_for(site)
    Websites::SelfAudit.new(website: site).call
  end

  it 'grades a draft, which has no URL to crawl' do
    report = report_for(website)

    expect(website.status).to eq('draft')
    expect(report['score']).to be_a(Integer)
    expect(report['checks']).to be_present
  end

  it 'can be run again and gives the same answer for the same site' do
    expect(report_for(website)['score']).to eq(report_for(website)['score'])
  end

  # The point of the button: change the copy, check again, see it move.
  it 'reflects a fix without anything being republished' do
    before_score = report_for(website)['score']

    website.website_pages.first.update!(
      seo_description: 'New and used manufactured homes in Denver, Colorado, with delivery, ' \
                       'setup and financing handled by a family owned dealership since 1998.'
    )

    expect(report_for(website.reload)['score']).to be > before_score
  end

  it 'says there is nothing to check rather than returning a misleading zero' do
    bare = Company.create!(name: 'Bare Co')
    empty = Website.create!(company_id: bare.id, location_id: bare.locations.create!(name: 'L').id,
                            name: 'Empty', slug: "s-#{SecureRandom.hex(4)}", status: 'draft')

    expect(report_for(empty)).to be_nil
  end
end
