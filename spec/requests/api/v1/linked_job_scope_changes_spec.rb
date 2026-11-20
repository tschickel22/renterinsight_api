# frozen_string_literal: true

require 'rails_helper'

# E106: the dealer is told who hears about a change before saving it, and a
# task added or changed on a phase a linked installer runs only crosses when
# sent, as a scope change the installer answers with a change order or "no
# charge".
RSpec.describe 'Linked job scope changes and who hears', type: :request do
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
  let!(:linked_addon) { TenantModuleOverride.create!(company: dealer_co, module_key: 'management.linked_companies', is_enabled: true) }
  before { boss }

  let(:project) do
    dealer_co.projects.create!(name: 'Diaz home', status: 'active', owner: dealer, customer_name: 'Maria Diaz',
                               delivery_city: 'Golden', delivery_state: 'CO')
  end
  let!(:prep_phase) { project.project_phases.create!(company: dealer_co, name: 'Site prep', position: 0, status: 'not_started') }
  let!(:set_phase) { project.project_phases.create!(company: dealer_co, name: 'Set', position: 1, status: 'not_started') }

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  def body = JSON.parse(response.body)

  let(:link) do
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: boss.email }.to_json
    id = body.dig('company_link', 'id')
    post "/api/v1/company_links/#{id}/accept", headers: h(boss), params: { agree: true }.to_json
    CompanyLink.find(id)
  end

  let(:pl) do
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_ids: [set_phase.id], price_mode: 'dealer', fee: '4000' }.to_json
    expect(response).to have_http_status(:created), response.body
    job = ProjectLink.find(body.dig('project_link', 'id'))
    post "/api/v1/project_links/#{job.id}/accept", headers: h(boss)
    expect(response).to have_http_status(:ok), response.body
    job.reload
  end

  def installer_phase = pl.link_phases.find_by(dealer_phase_id: set_phase.id).installer_phase

  def who(params)
    get "/api/v1/projects/#{project.id}/who_hears", headers: h(dealer), params: params
    expect(response).to have_http_status(:ok), response.body
    body['lines'].map { |l| l['text'] }
  end

  describe 'who hears' do
    it 'says moving dates tells the installer running a phase that moves, and not the customer' do
      pl
      lines = who(change: 'dates', phase_ids: [prep_phase.id, set_phase.id])
      expect(lines).to include('This tells Summit Install (bell, email and Review Updates), because they run Set.')
      expect(lines).to include('The customer is not told about date changes.')

      expect(who(change: 'dates', phase_ids: [prep_phase.id])).not_to include(a_string_including('Summit Install'))
    end

    it 'names the contractors who are not told' do
      task = prep_phase.project_phase_tasks.create!(company: dealer_co, name: 'Grade pad', position: 0)
      crew = Contractor.create!(company: dealer_co, name: 'Ace Grading', status: 'active')
      task.contractor_assignments.create!(company: dealer_co, contractor: crew, status: 'accepted')
      expect(who(change: 'dates', phase_ids: [prep_phase.id])).to include('Ace Grading is not told. Let them know yourself.')
    end

    it 'says the customer hears when a phase that emails them finishes' do
      project.update!(client_visible: true, customer_email: 'maria@example.com')
      prep_phase.update!(visible_to_client: true, notify_client_on_complete: true)
      lines = who(change: 'status', phase_id: prep_phase.id, status: 'completed')
      expect(lines.join).to include('The customer hears', 'by email')
    end

    it 'offers to send a new task on a handed-off phase' do
      pl
      expect(who(change: 'add_task', phase_id: set_phase.id).first).to include('stays on your project unless you send it')
      expect(who(change: 'add_task', phase_id: prep_phase.id)).to eq(['No one else is told.'])
    end
  end

  describe 'a task the dealer adds' do
    it 'stays on the dealer project when not sent' do
      pl
      post "/api/v1/projects/#{project.id}/phases/#{set_phase.id}/tasks", headers: h(dealer), params: { task: { name: 'Haul debris' } }.to_json
      expect(response).to have_http_status(:created)
      expect(body['sent_to_installer']).to be(false)
      expect(installer_phase.project_phase_tasks.where(name: 'Haul debris')).to be_empty
    end

    it 'does not hand the new task to the installer as a portal contractor too' do
      pl
      set_phase.update!(assigned_vendor_id: vendor.id)
      post "/api/v1/projects/#{project.id}/phases/#{set_phase.id}/tasks", headers: h(dealer), params: { task: { name: 'Haul debris' } }.to_json
      expect(ProjectPhaseTask.find(body['id']).contractor_assignments).to be_empty
    end

    it 'does not list the linked installer among contractors who are not told' do
      pl
      task = set_phase.project_phase_tasks.create!(company: dealer_co, name: 'Level', position: 9)
      task.contractor_assignments.create!(company: dealer_co, contractor: vendor, status: 'assigned')
      expect(who(change: 'dates', phase_ids: [set_phase.id])).not_to include(a_string_including('not told. Let them know'))
    end

    it 'labels the job cost line from the hand-off' do
      pl.update!(dealer_cost_item: nil) if pl.respond_to?(:dealer_cost_item)
      item = project.project_cost_items.create!(company: dealer_co, description: 'Installer: Set', amount: 4000, cost_type: 'subcontractor',
                                                status: 'pending', metadata: { 'source' => 'project_link' })
      expect(ProjectCostEntryService.source_for(item)).to eq('Linked installer job, committed')
    end

    it 'goes to the installer when sent, holds the phase, and no charge releases it' do
      pl
      post "/api/v1/projects/#{project.id}/phases/#{set_phase.id}/tasks", headers: h(dealer),
           params: { task: { name: 'Haul debris' }, send_to_installer: true }.to_json
      expect(body['sent_to_installer']).to be(true)
      copy = installer_phase.project_phase_tasks.find_by(name: 'Haul debris')
      expect(copy.linked_task_id).to eq(body['id'])

      change = pl.scope_changes.last
      expect(change).to have_attributes(kind: 'task_added', status: 'pending')
      expect(installer_co.review_items.open.find_by(kind: 'scope_changed').title).to include('Summit Homes changed the scope')
      expect(installer_phase.reload.price_hold_message).to include("can't start until you answer Summit Homes's scope change")

      post "/api/v1/project_link_scope_changes/#{change.id}/no_charge", headers: h(boss)
      expect(response).to have_http_status(:ok), response.body
      expect(change.reload.status).to eq('no_charge')
      expect(installer_phase.reload.price_hold_message).to be_nil
      expect(dealer_co.review_items.open.find_by(kind: 'scope_answered').title).to include('no charge')
    end

    it 'can be answered with a change order the dealer then approves' do
      pl
      post "/api/v1/projects/#{project.id}/phases/#{set_phase.id}/tasks", headers: h(dealer),
           params: { task: { name: 'Extra pier' }, send_to_installer: true }.to_json
      change = pl.scope_changes.last
      post "/api/v1/project_links/#{pl.id}/changes", headers: h(boss),
           params: { kind: 'change', description: 'Extra pier', scope_change_id: change.id,
                     lines: [{ name: 'Pier', qty: 1, price: '350' }] }.to_json
      expect(response).to have_http_status(:created), response.body
      expect(change.reload).to have_attributes(status: 'change_order', dealer_phase_id: set_phase.id)
      expect(change.link_change.dealer_phase_id).to eq(set_phase.id)
    end
  end

  it 'sends a changed task to the installer copy only when asked' do
    task = set_phase.project_phase_tasks.create!(company: dealer_co, name: 'Level', position: 0)
    pl
    copy = installer_phase.project_phase_tasks.find_by(linked_task_id: task.id)
    patch "/api/v1/projects/#{project.id}/phases/#{set_phase.id}/tasks/#{task.id}", headers: h(dealer),
          params: { task: { name: 'Level and anchor' } }.to_json
    expect(copy.reload.name).to eq('Level')

    patch "/api/v1/projects/#{project.id}/phases/#{set_phase.id}/tasks/#{task.id}", headers: h(dealer),
          params: { task: { estimated_start_date: '2026-12-01' }, send_to_installer: true }.to_json
    expect(response).to have_http_status(:ok), response.body
    expect(copy.reload).to have_attributes(name: 'Level and anchor', estimated_start_date: Date.new(2026, 12, 1))
    expect(pl.scope_changes.last.description).to include('start date none to Dec 1')
  end
end
