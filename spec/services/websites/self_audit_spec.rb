# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::SelfAudit do
  let(:company) do
    Company.create!(name: 'Summit Park Homes', phone: '555-0100', address_line1: '100 Lot Road',
                    city: 'Denver', state: 'CO', zip_code: '80231', industry: 'manufactured_housing')
  end
  let(:location) do
    company.locations.create!(name: 'Denver Showroom', address_line1: '100 Lot Road', city: 'Denver',
                              state: 'CO', zip_code: '80231', phone: '555-0100')
  end
  # Deliberately a draft. The whole point is grading a site before anyone can
  # see it, and a draft has no live URL to crawl.
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit Park',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'draft',
                    brand: { 'company_name' => 'Summit Park Homes',
                             'logo_url' => 'https://cdn.test/logo.png' })
  end

  before do
    website.website_pages.create!(
      title: 'Home', path: '/', order: 0,
      blocks: [{ 'type' => 'hero', 'order' => 0, 'content' => {
        'title' => 'Manufactured homes in Denver',
        'subtitle' => 'Family owned since 1998, serving the Front Range with new and used homes.'
      } }]
    )
    company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                             model: 'Prairie Dune', status: 'available', bedrooms: 3, bathrooms: 2,
                             square_feet: 1023, sale_price: 89_900,
                             images: [{ 'url' => 'https://cdn.test/front.jpg' }])
  end

  subject(:report) { described_class.new(website: website, canonical_host: 'summit.example.com').call }

  def check(key)
    report['checks'].find { |c| c['key'] == key }
  end

  it 'grades a site that has never been published' do
    expect(report['score']).to be_a(Integer)
    expect(report['pages_checked']).to be >= 2
  end

  it 'returns the same shape the prospect scan produces, so one reader fits both' do
    expect(report.keys).to include('score', 'gap_count', 'checks', 'score_explainer', 'domain')
  end

  it 'grades the listings, not only the brochure pages' do
    expect(check('structured_data')['status']).to eq('pass')
    expect(check('rich_results')['status']).to eq('pass')
  end

  it 'credits the dealership markup we emit' do
    expect(check('local_business')['status']).to eq('pass')
  end

  # A draft has no host to fetch from, and penalising it for that would be
  # reporting our own deployment model as the dealer's fault.
  it 'grades the crawler files it will serve rather than failing on a dead host' do
    expect(check('sitemap')['status']).to eq('pass')
    expect(check('robots')['status']).to eq('pass')
  end

  # A check we did not run must never quietly count as one the site passed.
  it 'says nothing about the parts of the page the app shell provides' do
    described_class::SHELL_DEPENDENT.each do |key|
      expect(check(key)).to be_nil, "#{key} was judged, but the shell is not ours to render here"
    end
  end

  # A site with no pages still has the dealer's listings, and those are real
  # pages we would serve, so they are graded.
  it 'grades the listings even when no page has been built yet' do
    pageless = Website.create!(company_id: company.id, location_id: location.id, name: 'Pageless',
                               slug: "s-#{SecureRandom.hex(4)}", status: 'draft')

    result = described_class.new(website: pageless, canonical_host: 'pageless.example.com').call

    expect(result['pages_checked']).to eq(1)
  end

  it 'is nil when there is genuinely nothing to grade' do
    bare = Company.create!(name: 'Bare Co')
    empty = Website.create!(company_id: bare.id, location_id: bare.locations.create!(name: 'Lot').id,
                            name: 'Empty', slug: "s-#{SecureRandom.hex(4)}", status: 'draft')

    expect(described_class.new(website: empty, canonical_host: 'empty.example.com').call).to be_nil
  end

  # If the controller gains a tag and this does not, a dealer would be graded on
  # a page that is not the one we serve.
  it 'assembles the same head tags the live controller does, in the same order' do
    served = File.read(Rails.root.join('app/controllers/public/sites_controller.rb'))
                 .match(/def head_tags(.*?)tags\.compact/m)[1]
    ours = File.read(Rails.root.join('app/services/websites/self_audit.rb'))
               .match(/tags = \[(.*?)\]\.compact/m)[1]

    names = ->(source) { source.scan(/'([a-z:_]+)'/).flatten }

    expect(names.call(ours)).to eq(names.call(served))
  end
end
