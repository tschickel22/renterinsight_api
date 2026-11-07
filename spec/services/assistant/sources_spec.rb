# frozen_string_literal: true

require 'rails_helper'

# What Quinn AI reads besides the dealer's own answers: FAQs and About text on
# the sites we host, and from the dealer's own site (E96, 2026-11-07).
RSpec.describe 'Quinn AI website sources', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let(:location) { company.locations.create!(name: 'Denver') }
  let!(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let!(:site) { company.websites.create!(location_id: location.id, name: 'Summit Site', slug: "s-#{SecureRandom.hex(4)}", status: 'published') }

  before do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.ai_concierge', is_enabled: true)
    site.website_pages.create!(title: 'FAQ', path: '/faq', blocks: [
      { 'type' => 'faq', 'content' => { 'faqs' => [{ 'question' => 'Do you deliver?', 'answer' => 'Yes, within 150 miles.' }] } }
    ])
    site.website_pages.create!(title: 'About Us', path: '/about', blocks: [
      { 'type' => 'text', 'content' => { 'html' => '<h2>Our Story</h2><p>Family owned in Denver.</p>' } }
    ])
  end

  let(:conversation) do
    lead = company.leads.create!(first_name: 'Tia', phone: '3035550144')
    company.conversations.create!(channel: 'sms', status: 'active', conversable: lead, buyer_phone: '3035550144', sender_number: '7205550100')
  end

  def prompt
    Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company), history: []).system_prompt
  end

  it 'reads the FAQs and About page on the sites we host, unless the dealer switches website text off' do
    expect(prompt).to include('Q: Do you deliver?').and include('Yes, within 150 miles.').and include('Family owned in Denver.')

    Assistant::Settings.for(company).update!('use_website_text' => false)
    expect(prompt).not_to include('Do you deliver?')
  end

  it 'reads the dealer\'s own site and prefers its About text' do
    Assistant::Settings.for(company).update!('chat_sites' => ['summitparkhomes.com'])
    SiteContentProfile.create!(company_id: company.id, source_url: 'https://www.summitparkhomes.com', status: 'ready', profile: {
                                 'copy' => { 'about' => [{ 'heading' => 'About', 'body' => 'Serving Colorado since 2004.' }],
                                             'faq' => [{ 'question' => 'Do you take trades?', 'answer' => 'Yes, we take trades.' }] }
                               })
    expect(Assistant::Sources.about(company)[:text]).to eq('Serving Colorado since 2004.')
    expect(Assistant::Sources.website_faqs(company).map { |f| f[:q] }).to include('Do you deliver?', 'Do you take trades?')
  end

  it 'shows what Quinn already knows in the settings, and reads the dealer\'s site on request' do
    get '/api/crm/lead_assistant_settings', headers: headers
    knowledge = JSON.parse(response.body)['knowledge']
    expect(knowledge['website_faqs'].first).to include('q' => 'Do you deliver?', 'source' => 'Summit Site')
    expect(knowledge['about']).to include('source' => 'Summit Site')
    expect(knowledge['company']['name']).to eq(company.name)

    allow(SiteProfiles::UrlGuard).to receive(:validate!).and_return(true)
    expect do
      post '/api/crm/lead_assistant_settings/read_site', params: { url: 'summitparkhomes.com' }.to_json, headers: headers
    end.to have_enqueued_job(SiteProfileScanJob)
    expect(JSON.parse(response.body)['knowledge']['reading']).to include('url' => 'https://summitparkhomes.com', 'status' => 'pending')
  end
end
