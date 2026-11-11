# frozen_string_literal: true

require 'rails_helper'

# A dealer bids a job out before closing, then hands it to the installer
# company it owns (Easy Homesource and AMHI). The awarded bids go with the
# job, as contractors and amounts, as phase budgets only, or not at all, and
# come off the dealer's project so its only cost for the work is the fee.
RSpec.describe 'Handing a bid job to a linked installer', type: :request do
  include ActiveJob::TestHelper

  let(:dealer_co) { create(:company, name: 'Easy Homesource') }
  let(:installer_co) { create(:company, name: 'AMHI') }

  def admin(company, email)
    User.create!(email: email, first_name: 'A', last_name: 'B', password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end

  let(:dealer) { admin(dealer_co, 'pat@ehs.example') }
  let(:boss) { admin(installer_co, 'boss@amhi.example') }
  let(:amhi_vendor) { Contractor.create!(company: dealer_co, name: 'AMHI', email: 'boss@amhi.example', status: 'active') }
  let!(:location) { installer_co.locations.first || installer_co.locations.create!(name: 'Yard', active: true) }
  let!(:linked_addon) { TenantModuleOverride.create!(company: dealer_co, module_key: 'management.linked_companies', is_enabled: true) }
  before { boss }

  let(:project) do
    dealer_co.projects.create!(name: 'Megan Ortiz home', status: 'active', owner: dealer, customer_name: 'Megan Ortiz',
                               delivery_city: 'Pueblo', delivery_state: 'CO')
  end
  let!(:utility) { project.project_phases.create!(company: dealer_co, name: 'Utility Connections', position: 0, status: 'not_started') }
  let!(:land) { project.project_phases.create!(company: dealer_co, name: 'Land Prep', position: 1, status: 'not_started') }
  let!(:utility_task) { utility.project_phase_tasks.create!(company: dealer_co, name: 'Run water and sewer', position: 0) }

  let(:rampart) do
    Contractor.create!(company: dealer_co, name: 'Rampart Utilities', email: 'bids@rampart.example', phone: '7195550100',
                       status: 'active', sms_opt_in: true, sms_consent_source: Vendor::SMS_CONSENT_SOURCES.first, tax_id: '84-1234567')
  end
  let(:front_range) { Contractor.create!(company: dealer_co, name: 'Front Range Excavating', email: 'office@frontrange.example', status: 'active') }
  # AMHI already works with Front Range under its own record.
  let!(:amhi_front_range) { Contractor.create!(company: installer_co, name: 'Front Range Excavating LLC', email: 'Office@FrontRange.example', status: 'active') }

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  def body = JSON.parse(response.body)

  let(:link) do
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: amhi_vendor.id, email: boss.email }.to_json
    id = body.dig('company_link', 'id')
    post "/api/v1/company_links/#{id}/accept", headers: h(boss), params: { agree: true }.to_json
    CompanyLink.find(id)
  end

  def award!(phase, vendor, amount)
    bids = ProjectBidService.new(dealer_co, actor: dealer)
    request = bids.send_request!(project: project, phase: phase, vendor_ids: [vendor.id])
    bid = request.bids.find_by!(vendor_id: vendor.id)
    bids.submit!(bid, amount: amount, entered_by: dealer, notes: 'Includes trenching')
    bids.award!(request, bid.reload, notify_others: false)
    request.reload
  end

  def send!(handover: nil, phases: [utility, land], fee: '9000', status: :created)
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_ids: phases.map(&:id), price_mode: 'dealer', fee: fee,
                   handover: handover }.compact.to_json
    expect(response).to have_http_status(status), response.body
    status == :created ? ProjectLink.find(body.dig('project_link', 'id')) : body
  end

  def accept!(pl)
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    expect(response).to have_http_status(:ok), response.body
    pl.reload
  end

  def installer_phase(pl, phase) = pl.link_phases.find_by(dealer_phase_id: phase.id).installer_phase

  before do
    award!(utility, rampart, 4450)
    award!(land, front_range, 2950)
  end

  it 'previews which bids move and whether the installer has each contractor' do
    get "/api/v1/projects/#{project.id}/project_links/handover_preview", headers: h(dealer),
        params: { company_link_id: link.id, project_phase_ids: [utility.id, land.id] }
    expect(response).to have_http_status(:ok), response.body
    expect(body['moving_total']).to eq(7400.0)
    expect(body['blockers']).to eq([])
    expect(body['bids'].map { |b| [b['vendor_name'], b['amount'], b['at_installer']] })
      .to contain_exactly(['Rampart Utilities', 4450.0, 'new'], ['Front Range Excavating', 2950.0, 'existing'])
  end

  it 'sends the contractors and amounts: awarded and committed at the installer, off the dealer' do
    expect(project.reload.committed_cost).to eq(7400)
    expect(utility_task.contractor_assignments.where(vendor_id: rampart.id)).to exist

    pl = send!(handover: 'contractors')
    # The dealer's only cost for the work is now the installer's fee.
    expect(project.reload.committed_cost).to eq(9000)
    expect(utility_task.contractor_assignments.where(vendor_id: rampart.id)).not_to exist
    expect(utility.reload.assigned_vendor_id).to eq(amhi_vendor.id)
    # Its Bids tab says where the work went, and the award can't be undone under the installer.
    request = dealer_co.project_bid_requests.find_by!(project_phase_id: utility.id)
    expect(request.as_api_json[:sent_to_installer]).to eq('AMHI')
    expect { ProjectBidService.new(dealer_co, actor: dealer).undo_award!(request) }
      .to raise_error(ProjectBidService::Error, /with AMHI now/)

    perform_enqueued_jobs { accept!(pl) }
    copy = pl.installer_project
    expect(copy.committed_cost).to eq(7400)

    rampart_there = installer_co.vendors.find_by!(name: 'Rampart Utilities')
    expect(rampart_there).to have_attributes(email: 'bids@rampart.example', tax_id: '84-1234567', sms_opt_in: false)
    expect(installer_co.vendors.where('lower(name) LIKE ?', 'front range%').count).to eq(1)

    ip = installer_phase(pl, utility)
    expect(ip).to have_attributes(assigned_vendor_id: rampart_there.id, estimated_budget: 4450)
    expect(installer_phase(pl, land)).to have_attributes(assigned_vendor_id: amhi_front_range.id, estimated_budget: 2950)
    expect(ip.project_phase_tasks.first.contractor_assignments.pluck(:vendor_id)).to eq([rampart_there.id])

    request = installer_co.project_bid_requests.find_by!(project_phase_id: ip.id)
    expect(request).to have_attributes(status: 'awarded')
    expect(request.awarded_bid).to have_attributes(vendor_id: rampart_there.id, amount: 4450, status: 'awarded')
    expect(request.awarded_bid.project_cost_item).to have_attributes(amount: 4450, status: 'pending', project_phase_id: ip.id)

    # The installer's list shows what came with the job.
    get '/api/v1/company_links', headers: h(boss)
    job = body['jobs'].find { |j| j['id'] == pl.id }
    expect(job['handover_bids'].map { |b| b['vendor_name'] }).to contain_exactly('Rampart Utilities', 'Front Range Excavating')
  end

  it 'sends the bid amounts as phase budgets only' do
    pl = accept!(send!(handover: 'budget'))
    expect(installer_phase(pl, utility).estimated_budget).to eq(4450)
    expect(installer_phase(pl, land).estimated_budget).to eq(2950)
    expect(pl.installer_project.project_cost_items.count).to eq(0)
    expect(installer_co.vendors.where(name: 'Rampart Utilities')).not_to exist
    expect(project.reload.committed_cost).to eq(9000)
  end

  it 'sends an empty job, and the bids still leave the dealer' do
    pl = accept!(send!(handover: 'empty'))
    expect(installer_phase(pl, utility).estimated_budget).to be_nil
    expect(pl.installer_project.project_cost_items.count).to eq(0)
    expect(project.reload.committed_cost).to eq(9000)
  end

  it 'puts the bids back on the dealer when the installer declines or the job is taken back' do
    pl = send!(handover: 'contractors')
    post "/api/v1/project_links/#{pl.id}/decline", headers: h(boss), params: { reason: 'Booked' }.to_json
    expect(response).to have_http_status(:ok), response.body
    expect(project.reload.committed_cost).to eq(7400)
    expect(utility.reload.assigned_vendor_id).to eq(rampart.id)
    expect(utility_task.contractor_assignments.where(vendor_id: rampart.id)).to exist

    pl = send!(handover: 'contractors')
    post "/api/v1/project_links/#{pl.id}/cancel", headers: h(dealer)
    expect(response).to have_http_status(:ok), response.body
    expect(project.reload.committed_cost).to eq(7400)
    expect(utility_task.reload.contractor_assignments.where(vendor_id: rampart.id).count).to eq(1)
  end

  it 'will not send work with open bids or that a contractor has started, and keeps billed bids' do
    other = project.project_phases.create!(company: dealer_co, name: 'Skirting', position: 2, status: 'not_started')
    ProjectBidService.new(dealer_co, actor: dealer).send_request!(project: project, phase: other, vendor_ids: [rampart.id])
    err = send!(phases: [other], status: :unprocessable_entity)
    expect(err['error']).to include('Skirting still has open bids')

    utility_task.contractor_assignments.find_by!(vendor_id: rampart.id).update!(status: 'in_progress')
    err = send!(phases: [utility], status: :unprocessable_entity)
    expect(err['error']).to include('Rampart Utilities has started Utility Connections')

    # Front Range already billed: that cost stays with the dealer.
    land_cost = land.project_cost_items.not_deleted.first
    land_cost.update!(status: 'approved')
    pl = accept!(send!(handover: 'contractors', phases: [land]))
    expect(land_cost.reload.is_deleted).to be(false)
    expect(pl.handover_bids).to eq([])
    expect(pl.installer_project.project_cost_items.count).to eq(0)
  end
end
