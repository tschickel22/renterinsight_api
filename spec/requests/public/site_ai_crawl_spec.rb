# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public::Sites AI crawling', type: :request do
  let(:company)  { Company.create!(name: "Co-#{SecureRandom.hex(3)}", phone: '303-555-0100') }
  let(:location) do
    company.locations.create!(name: 'Showroom', address_line1: '12 Main St', city: 'Denver', state: 'CO',
                              zip_code: '80202', business_hours: { 'monday' => { 'open' => '09:00', 'close' => '17:00' },
                                                                   'sunday' => { 'closed' => true } })
  end
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Sunshine RV',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published',
                    brand: { 'company_name' => 'Sunshine RV' }, seo_config: { 'default_description' => 'Homes in Denver.' })
  end
  let!(:home) { website.website_pages.create!(title: 'Home', path: '/', order: 0, blocks: []) }
  let!(:about) { website.website_pages.create!(title: 'About', path: '/about', order: 1, seo_description: 'Who we are', blocks: []) }
  let!(:promo) do
    website.website_pages.create!(title: 'Promo', path: '/promo', order: 2, blocks: [], robots: 'noindex, nofollow',
                                  canonical_path: '/about')
  end
  let!(:domain) do
    company.company_domains.create!(hostname: 'sunshine-rv.test', website_id: website.id, verification_status: 'active')
  end

  before do
    Rails.cache.clear
    allow(Websites::SpaShell).to receive(:fetch) do
      Websites::SpaShell.absolutize('<!doctype html><html><head><title>App</title></head><body><div id="root"></div></body></html>',
                                    'https://spa.example.com')
    end
  end

  def get_site(path) = get(path, headers: { 'HTTP_HOST' => 'sunshine-rv.test' })

  it 'serves llms.txt with the facts and links' do
    get_site('/llms.txt')

    expect(response).to have_http_status(:ok)
    expect(response.body).to start_with("# Sunshine RV\n\n> Homes in Denver.")
    expect(response.body).to include('- Address: 12 Main St, Denver, CO 80202', '- Phone: 303-555-0100',
                                     'Monday 09:00-17:00; Sunday closed',
                                     '- [About](https://sunshine-rv.test/about): Who we are')
    expect(response.body).not_to include('Promo')
  end

  it 'names AI crawlers in robots.txt' do
    get_site('/robots.txt')
    expect(response.body).to include("User-agent: GPTBot\nAllow: /", "User-agent: ClaudeBot\nAllow: /",
                                     "User-agent: PerplexityBot\nAllow: /")
  end

  it 'answers 404 and noindex for a path that names nothing' do
    get_site('/no-such-page')
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include('noindex')
    expect(response.body).not_to include('rel="canonical"')
  end

  it 'still serves /homes' do
    get_site('/homes')
    expect(response).to have_http_status(:ok)
  end

  it "honours a page's own robots and canonical" do
    get_site('/promo')
    expect(response.body).to include('content="noindex, nofollow"', 'href="https://sunshine-rv.test/about"')
  end

  it 'leaves noindex pages out of the sitemap' do
    get_site('/sitemap.xml')
    expect(response.body).to include('/about')
    expect(response.body).not_to include('/promo')
  end
end
