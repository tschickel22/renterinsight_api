# frozen_string_literal: true

require 'rails_helper'

# The quote details sheet crosses to the linked installer company, even when
# they took only some phases of the job; it goes away with the switch.
RSpec.describe 'Quote details reach the linked installer', type: :request do
  include ActiveJob::TestHelper

  let(:dealer_co) { create(:company, name: 'Summit Homes') }
  let(:installer_co) { create(:company, name: 'Summit Install') }

  def admin(company, email)
    User.create!(email: email, first_name: 'A', last_name: 'B', password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end

  let(:dealer) { admin(dealer_co, 'pat@summit.example') }
  let(:boss) { admin(installer_co, 'boss@install.example') }
  let(:vendor) { Contractor.create!(company: dealer_co, name: 'Summit Install (vendor)', email: 'boss@install.example', status: 'active') }
  let!(:location) { installer_co.locations.first || installer_co.locations.create!(name: 'Yard', active: true) }
  let!(:dealer_location) { dealer_co.locations.first || dealer_co.locations.create!(name: 'Lot', active: true) }
  let!(:linked_addon) { TenantModuleOverride.create!(company: dealer_co, module_key: 'management.linked_companies', is_enabled: true) }
  let(:deal) do
    dealer_co.deals.create!(location: dealer_location, name: 'Diaz home', account: dealer_co.accounts.create!(name: 'Diaz'), stage: 'negotiation')
  end
  let!(:quote) do
    dealer_co.quotes.create!(quote_number: 'Q-1001', status: 'accepted', accepted_at: Time.current, deal_id: deal.id,
                             items: [{ 'description' => 'Skirting, vinyl', 'quantity' => 1, 'total' => 2400, 'category' => 'accessory' }])
  end
  let(:project) do
    dealer_co.projects.create!(name: 'Diaz home', status: 'active', owner: dealer, customer_name: 'Maria Diaz', deal: deal)
  end
  let!(:set_phase) { project.project_phases.create!(company: dealer_co, name: 'Set', position: 0, status: 'not_started') }
  let!(:finish_phase) { project.project_phases.create!(company: dealer_co, name: 'Finish', position: 1, status: 'not_started') }

  before do
    boss
    allow(PrivateFiles).to receive(:put) { |_body, key:, **| "private://dealertide-private-test/#{key}" }
    allow(PrivateFiles).to receive(:copy) { |_v, folder:| { ref: "private://dealertide-private-test/#{folder}/copy.pdf", key: "#{folder}/copy.pdf" } }
    allow(PrivateFiles).to receive(:delete)
  end

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  def body = JSON.parse(response.body)

  def accepted_phase_job!
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: boss.email }.to_json
    link = CompanyLink.find(body.dig('company_link', 'id'))
    post "/api/v1/company_links/#{link.id}/accept", headers: h(boss), params: { agree: true }.to_json
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
                                                         params: { company_link_id: link.id, project_phase_id: set_phase.id, fee: 4500 }.to_json
    pl = ProjectLink.find(body.dig('project_link', 'id'))
    perform_enqueued_jobs { post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss) }
    expect(response).to have_http_status(:ok), response.body
    pl.reload
  end

  def installer_sheets(pl)
    ProjectDocument.not_deleted.where(project_id: pl.installer_project_id).where("title LIKE 'Quote details%'")
  end

  it 'crosses to an installer that took one phase, names them, and is taken back when switched off' do
    pl = accepted_phase_job!
    expect(pl.whole_project?).to be(false)

    perform_enqueued_jobs { post "/api/v1/projects/#{project.id}/quote_details", headers: h(dealer) }
    expect(response).to have_http_status(:created), response.body
    expect(body['installer']).to eq('Summit Install')
    expect(installer_sheets(pl).count).to eq(1)

    perform_enqueued_jobs { delete "/api/v1/projects/#{project.id}/quote_details", headers: h(dealer) }
    expect(installer_sheets(pl).count).to eq(0)
  end
end
