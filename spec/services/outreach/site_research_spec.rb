# frozen_string_literal: true

require 'rails_helper'

# Reading a retailer's own site before the first message (backlog E105).
RSpec.describe Outreach::SiteResearch do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:tom) do
    User.create!(email: "t-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:wave) { company.outreach_waves.create!(name: 'W', status: 'drafting') }

  let(:home_html) do
    <<~HTML
      <html><head><title>Sunrise Homes of Biloxi | New Manufactured Homes</title>
      <meta name="description" content="Clayton and Champion homes in Biloxi, MS."></head>
      <body><nav><a href="/inventory">Homes for sale</a><a href="/about">About</a>
      <a href="https://www.facebook.com/sunrisehomesbiloxi">Facebook</a></nav>
      <h1>Sunrise Homes of Biloxi</h1><p>Family owned since 1998, we carry Clayton and Champion homes on our Biloxi lot. Call 228-555-0144.</p></body></html>
    HTML
  end
  let(:inventory_html) { '<html><head><title>Inventory</title></head><body><h1>42 homes in stock</h1><p>Browse our 42 homes ready to move in this month on the Biloxi lot.</p></body></html>' }

  def response(url, body)
    SiteProfiles::Fetcher::Response.new(url: url, status: 200, body: body, content_type: 'text/html')
  end

  def target_for(lead)
    wave.outreach_targets.create!(company_id: company.id, lead_id: lead.id, channel: 'email')
  end

  def notes(lead)
    Note.where(entity_type: 'lead', entity_id: lead.id.to_s).pluck(:content)
  end

  before do
    allow(SiteProfiles::UrlGuard).to receive(:safe?).and_return(true)
    allow_any_instance_of(SiteProfiles::Fetcher).to receive(:get) do |_f, url, **|
      url.include?('inventory') ? response(url, inventory_html) : response(url, home_html)
    end
    allow_any_instance_of(SiteProfiles::Fetcher).to receive(:robots_allows?).and_return(true)
    allow(Outreach::AiClient).to receive(:call).and_return(
      'summary' => 'Family owned since 1998, selling Clayton and Champion homes in Biloxi, MS.',
      'brands' => %w[Clayton Champion], 'homes_listed' => 42, 'locations' => ['Biloxi, MS'],
      'opener_fact' => 'Family owned in Biloxi since 1998', 'talking_points' => ['TrueBuild lets buyers design one of their Clayton homes online']
    )
  end

  it 'reads a business email domain whose site names the lead, notes a summary, and feeds the opener' do
    lead = company.leads.create!(first_name: 'Ann', last_name: 'Lee', company_name: 'Sunrise Homes', email: 'ann@sunrisebiloxi.com',
                                 owner_id: tom.id, status: 'new')
    target = target_for(lead)
    research = described_class.for(target)

    expect(research).to include('status' => 'found', 'url' => 'https://sunrisebiloxi.com', 'from' => 'email', 'homes_listed' => 42,
                                'opener_fact' => 'Family owned in Biloxi since 1998')
    expect(research.dig('social', 'facebook')).to include('facebook.com/sunrisehomesbiloxi')
    expect(research['pages_read']).to be >= 2
    note = notes(lead).last
    expect(note).to include('Website research', 'Brands: Clayton, Champion', 'Homes listed: about 42', 'Facebook: https://www.facebook.com/sunrisehomesbiloxi')
    expect(LeadActivity.where(lead_id: lead.id)).to be_empty

    facts = Outreach::Writer.new(target.reload).send(:website_facts)
    expect(facts).to include('Fact to open with: Family owned in Biloxi since 1998')
  end

  it 'never reads free mail, and refuses a business domain whose site is someone else' do
    gmail = company.leads.create!(first_name: 'G', last_name: 'M', company_name: 'Sunrise Homes', email: 'g@gmail.com', owner_id: tom.id, status: 'new')
    expect(described_class.for(target_for(gmail))['status']).to eq('no_site')

    other = company.leads.create!(first_name: 'O', last_name: 'T', company_name: 'Pinecrest Housing', email: 'o@bighost.com', owner_id: tom.id, status: 'new')
    expect(described_class.for(target_for(other))['status']).to eq('mismatch')
    expect(notes(other)).to be_empty
    expect(Outreach::AiClient).not_to have_received(:call)
  end

  it 'trusts the website field without a name match and reuses a recent read instead of fetching again' do
    lead = company.leads.create!(first_name: 'W', last_name: 'F', company_name: 'Different Name LLC', email: 'w@gmail.com', owner_id: tom.id,
                                 status: 'new', custom_field_values: { 'website' => 'sunrisebiloxi.com' })
    expect(described_class.for(target_for(lead))['status']).to eq('found')

    later = company.outreach_waves.create!(name: 'Later', status: 'drafting')
    again = later.outreach_targets.create!(company_id: company.id, lead_id: lead.id, channel: 'email')
    expect(described_class.for(again)['status']).to eq('found')
    expect(Outreach::AiClient).to have_received(:call).once
    expect(notes(lead).size).to eq(1)
  end

  it 'leaves the ordinary opener when the site cannot be read' do
    allow_any_instance_of(SiteProfiles::Fetcher).to receive(:get).and_return(nil)
    lead = company.leads.create!(first_name: 'D', last_name: 'N', company_name: 'Down', email: 'd@downsite.com', owner_id: tom.id, status: 'new')
    target = target_for(lead)
    expect(described_class.for(target)['status']).to eq('unreachable')
    expect(Outreach::Writer.new(target.reload).send(:website_facts)).to eq('')
  end
end
