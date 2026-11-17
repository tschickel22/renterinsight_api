# frozen_string_literal: true

require 'rails_helper'

# "Share quote details with installers": a scope sheet of the deal's quote on
# the project, for the installer, with no prices.
RSpec.describe 'Project quote details for installers', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:account) { company.accounts.create!(name: 'Diaz') }
  let(:deal) { company.deals.create!(location: location, name: 'Diaz home', account: account, stage: 'negotiation') }
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active', customer_name: 'Ana Diaz', deal: deal) }
  let!(:quote) do
    company.quotes.create!(quote_number: "Q-#{SecureRandom.hex(3)}", status: 'accepted', accepted_at: Time.current, deal_id: deal.id,
                           items: [
                             { 'description' => 'Aspire 023 (1444H11023)', 'quantity' => 1, 'unit_price' => 39_109.38, 'total' => 39_109.38,
                               'unit_cost' => 31_000, 'category' => 'home', 'notes' => '' },
                             { 'description' => 'Skirting, vinyl, 160 lf', 'quantity' => 1, 'unit_price' => 2400, 'total' => 2400,
                               'category' => 'accessory', 'notes' => 'Color: Clay' },
                             { 'description' => 'Spring promo', 'quantity' => 1, 'unit_price' => -500, 'total' => -500, 'category' => 'other' },
                             { 'description' => 'Freight to homesite', 'quantity' => 1, 'total' => 1800, 'category' => 'fee' },
                             { 'description' => 'Down Payment', 'quantity' => 1, 'total' => 5000, 'category' => 'service' }
                           ])
  end
  let(:stored) { {} }

  before do
    allow(PrivateFiles).to receive(:put) { |body, key:, **| stored[key] = body; "private://dealertide-private-test/#{key}" }
    allow(PrivateFiles).to receive(:delete)
    allow(PrivateFiles).to receive(:url) { |v, **| "https://s3.example.com/#{v.to_s.split('/').last}" }
  end

  def body = JSON.parse(response.body)

  def pdf_text(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")

  it 'makes a sheet of every work line, with no prices or cost, kept from the buyer and contractors' do
    post "/api/v1/projects/#{project.id}/quote_details", headers: headers
    expect(response).to have_http_status(:created), response.body
    expect(body).to include('enabled' => true, 'lines' => 2)

    doc = project.project_documents.not_deleted.last
    expect(doc).to have_attributes(contractor_visible: false, client_visible: false)
    expect(doc.shown_to_contractor?).to be(false)
    expect(doc.shown_to_client?).to be(false)

    text = pdf_text(stored.values.last)
    expect(text).to include('Aspire 023', 'Skirting, vinyl, 160 lf', 'Color: Clay', quote.quote_number)
    expect(text).not_to include('39,109', '39109', '31000', '31,000', '2400', '2,400', 'Spring promo', 'Freight', 'Down Payment', '$')
  end

  it 'is not on a contractor task view' do
    phase = project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started')
    task = phase.project_phase_tasks.create!(company: company, name: 'Set and level', position: 0)
    post "/api/v1/projects/#{project.id}/quote_details", headers: headers

    expect(ProjectMedia.contractor_files_for_task(task).map { |f| f[:title] }).not_to include(a_string_starting_with('Quote details'))
  end

  it 'remakes the sheet when the quote items change, and removes it when turned off' do
    post "/api/v1/projects/#{project.id}/quote_details", headers: headers
    first = project.project_documents.not_deleted.last

    quote.update!(items: quote.items + [{ 'description' => 'Steps, 3 ft', 'quantity' => 2, 'total' => 300, 'category' => 'accessory' }])
    ProjectQuoteDetails.quote_changed(quote)
    current = project.project_documents.not_deleted.where("metadata ->> 'quote_details' = 'true'")
    expect(current.count).to eq(1)
    expect(current.first.id).not_to eq(first.id)
    expect(pdf_text(stored.values.last)).to include('Steps, 3 ft')

    delete "/api/v1/projects/#{project.id}/quote_details", headers: headers
    expect(body['enabled']).to be(false)
    expect(project.project_documents.not_deleted.where("metadata ->> 'quote_details' = 'true'")).to be_empty
  end

  it 'says so when the deal has no quote' do
    quote.update!(is_deleted: true)
    post "/api/v1/projects/#{project.id}/quote_details", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('no quote')
  end
end
