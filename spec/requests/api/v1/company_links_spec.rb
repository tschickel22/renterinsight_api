# frozen_string_literal: true

require 'rails_helper'

# E68 step 5: a dealer links a vendor to the installer's own company, hands it
# a phase, the installer accepts and works it in its own company, status comes
# back to the dealer's project, and the installer bills the dealer.
RSpec.describe 'Company links', type: :request do
  include ActiveJob::TestHelper

  let(:dealer_co) { create(:company, name: 'Summit Homes') }
  let(:installer_co) { create(:company, name: 'Summit Install') }
  let(:stranger_co) { create(:company, name: 'Someone Else') }

  def admin(company, email)
    User.create!(email: email, first_name: 'A', last_name: 'B', password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end

  let(:dealer) { admin(dealer_co, 'pat@summit.example') }
  let(:boss) { admin(installer_co, 'boss@install.example') }
  let(:stranger) { admin(stranger_co, 'x@else.example') }
  let(:vendor) { Contractor.create!(company: dealer_co, name: 'Summit Install (vendor)', email: 'boss@install.example', status: 'active') }
  let!(:location) { installer_co.locations.first || installer_co.locations.create!(name: 'Yard', active: true) }

  let(:project) do
    dealer_co.projects.create!(name: 'Diaz home', status: 'active', owner: dealer, customer_name: 'Maria Diaz',
                               customer_email: 'maria@example.com', customer_phone: '303-555-0100',
                               delivery_street: '1 Elm', delivery_city: 'Golden', delivery_state: 'CO', client_visible: true)
  end
  let!(:set_phase) { project.project_phases.create!(company: dealer_co, name: 'Set', position: 0, status: 'not_started', visible_to_client: true) }
  let!(:finish_phase) { project.project_phases.create!(company: dealer_co, name: 'Finish', position: 1, status: 'not_started') }

  before do
    set_phase.project_phase_tasks.create!(company: dealer_co, name: 'Set and level', position: 0)
    set_phase.project_phase_tasks.create!(company: dealer_co, name: 'Tie down', position: 1)
  end

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  def body = JSON.parse(response.body)

  def link!
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: 'Boss@Install.example' }.to_json
    expect(response).to have_http_status(:created), response.body
    id = body.dig('company_link', 'id')
    post "/api/v1/company_links/#{id}/accept", headers: h(boss), params: { agree: true }.to_json
    expect(response).to have_http_status(:ok), response.body
    CompanyLink.find(id)
  end

  def offer!(link, phase: set_phase, fee: 4500)
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_id: phase&.id, fee: fee, note: 'Set by the 20th' }.to_json
    expect(response).to have_http_status(:created), response.body
    ProjectLink.find(body.dig('project_link', 'id'))
  end

  it 'links only after an admin with the invited email agrees, from inside their company' do
    boss
    # Works at both companies with one sign-in.
    User.create!(email: boss.email, primary_user: boss, company_id: dealer_co.id, first_name: 'A', last_name: 'B',
                 role: 'company_admin', status: 'active', password: SecureRandom.hex(16))
    expect {
      post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: 'boss@install.example' }.to_json
    }.to have_enqueued_job(CompanyLinkInviteEmailJob)
    id = body.dig('company_link', 'id')
    expect(Notification.where(recipient: boss, notification_type: 'company_link').count).to eq(1)
    expect(Notification.where(company_id: dealer_co.id, notification_type: 'company_link')).to be_empty

    get '/api/v1/company_links', headers: h(boss)
    expect(body['invitations'].map { |l| l['dealer_company_name'] }).to eq(['Summit Homes'])

    get '/api/v1/company_links', headers: h(stranger)
    expect(body['invitations']).to be_empty
    post "/api/v1/company_links/#{id}/accept", headers: h(stranger), params: { agree: true }.to_json
    expect(response).to have_http_status(:not_found)

    post "/api/v1/company_links/#{id}/accept", headers: h(boss), params: {}.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/company_links/#{id}/accept", headers: h(boss), params: { agree: true }.to_json
    link = CompanyLink.find(id)
    expect(link).to be_active
    expect(link.installer_company).to eq(installer_co)
    expect(link.installer_dealer_account.name).to eq('Summit Homes')
    expect(link.events.pluck(:kind)).to eq(%w[invited accepted])
  end

  it 'hands a phase across, syncs status and dates, and bills the dealer' do
    link = link!
    pl = offer!(link)
    expect(set_phase.reload.assigned_vendor_id).to eq(vendor.id)
    expect(pl.dealer_cost_item).to have_attributes(amount: 4500, status: 'pending', vendor_id: vendor.id, project_phase_id: set_phase.id)

    get '/api/v1/company_links', headers: h(boss)
    job = body['jobs'].first
    expect(job).to include('customer_name' => 'Maria Diaz', 'customer_phone' => '303-555-0100', 'scope_label' => 'Set', 'fee_amount' => 4500.0)
    expect(job['site']).to include('Golden')
    expect(job['phases'].first['tasks']).to eq(['Set and level', 'Tie down'])
    expect(job.keys.grep(/price|gross|cost/)).to be_empty

    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    expect(response).to have_http_status(:ok), response.body
    ip = pl.reload.installer_project
    expect(ip.company).to eq(installer_co)
    expect(ip).to have_attributes(customer_name: 'Maria Diaz', delivery_city: 'Golden', client_visible: false)
    iph = ip.project_phases.first
    expect(iph.project_phase_tasks.map(&:name)).to eq(['Set and level', 'Tie down'])
    expect(iph.visible_to_client).to be(false)
    expect(ip.current_phase_id).to eq(iph.id)

    # The dealer can't move a phase the installer runs.
    post "/api/v1/projects/#{project.id}/set_phase_status", headers: h(dealer), params: { phase_id: set_phase.id, status: 'in_progress' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('run by Summit Install')

    # The installer starts it; the dealer's phase follows (through the path
    # that sends the customer's phase notice).
    expect(ProjectNotificationService).to receive(:notify_phase_change).with(have_attributes(id: iph.id), anything, anything).and_call_original
    expect(ProjectNotificationService).to receive(:notify_phase_change).with(have_attributes(id: set_phase.id), 'not_started', 'in_progress').and_call_original
    perform_enqueued_jobs { ip.set_phase_status!(iph, 'in_progress') }
    expect(set_phase.reload.status).to eq('in_progress')

    # The dealer moves the install date; the installer's phase follows.
    perform_enqueued_jobs { set_phase.update!(estimated_start_date: Date.new(2026, 11, 20)) }
    expect(iph.reload.estimated_start_date).to eq(Date.new(2026, 11, 20))

    allow(ProjectNotificationService).to receive(:notify_phase_change)
    perform_enqueued_jobs { ip.set_phase_status!(iph.reload, 'completed') }
    expect(set_phase.reload.status).to eq('completed')
    expect(pl.reload.status).to eq('done')

    post "/api/v1/project_links/#{pl.id}/bill", headers: h(boss), params: { amount: '4,500' }.to_json
    expect(response).to have_http_status(:ok), response.body
    pl.reload
    expect(pl.installer_invoice).to have_attributes(company_id: installer_co.id, total: 4500, status: 'finalized', recipient: link.installer_dealer_account)
    # A company made today starts with invoice posting on, so the invoice is in the installer's books.
    expect(pl.installer_invoice.gl_post_error).to be_nil
    expect(JournalEntry.where(company_id: installer_co.id, source_entity_type: 'Invoice', source_entity_id: pl.installer_invoice_id)).to exist
    expect(pl.dealer_bill).to have_attributes(company_id: dealer_co.id, status: 'draft', vendor_id: vendor.id, project_id: project.id, source: 'linked_installer',
                                             due_date: pl.installer_invoice.due_date)
    expect(pl.dealer_cost_item.reload.bill_id).to eq(pl.dealer_bill_id)

    post "/api/v1/project_links/#{pl.id}/bill", headers: h(boss), params: { amount: 100 }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(link.events.pluck(:kind)).to include('job_offered', 'job_accepted', 'synced', 'job_done', 'job_billed')
  end

  it 'gives the phase back when the installer declines, and lets the dealer take a job back' do
    crew = Contractor.create!(company: dealer_co, name: 'Old crew', status: 'active')
    finish_phase.update!(assigned_vendor_id: crew.id)
    project.update!(assigned_vendor_id: crew.id)
    link = link!
    pl = offer!(link, phase: finish_phase, fee: 900)
    expect(finish_phase.reload.assigned_vendor_id).to eq(vendor.id)
    line_id = pl.dealer_cost_item_id

    post "/api/v1/project_links/#{pl.id}/decline", headers: h(boss), params: { reason: 'Booked that week' }.to_json
    expect(pl.reload.status).to eq('declined')
    expect(finish_phase.reload.assigned_vendor_id).to eq(crew.id)
    expect(ProjectCostItem.exists?(line_id)).to be(false)
    expect(Notification.where(recipient: dealer, notification_type: 'project_link').last.message).to include('Booked that week')

    whole = offer!(link, phase: nil, fee: nil)
    expect(project.reload.assigned_vendor_id).to eq(vendor.id)
    post "/api/v1/project_links/#{whole.id}/cancel", headers: h(dealer)
    expect(whole.reload.status).to eq('cancelled')
    expect(project.reload.assigned_vendor_id).to eq(crew.id)
    expect(finish_phase.reload.assigned_vendor_id).to eq(crew.id)
    expect(set_phase.reload.assigned_vendor_id).to be_nil
  end

  it 'keeps each side to its own records' do
    link = link!
    pl = offer!(link)

    post "/api/v1/project_links/#{pl.id}/accept", headers: h(stranger)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(dealer)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/project_links/#{pl.id}/cancel", headers: h(boss)
    expect(response).to have_http_status(:not_found)
    get "/api/v1/projects/#{project.id}/project_links", headers: h(boss)
    expect(response).to have_http_status(:not_found)

    # A link the dealer hasn't got can't be used to send work.
    other = CompanyLink.create!(dealer_company: stranger_co, dealer_vendor: Contractor.create!(company: stranger_co, name: 'V', status: 'active'),
                                invite_email: 'boss@install.example', installer_company: installer_co, status: 'active')
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer), params: { company_link_id: other.id, project_phase_id: finish_phase.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    # After the link ends no new work crosses, and the installer can't answer.
    post "/api/v1/company_links/#{link.id}/end", headers: h(boss)
    expect(link.reload.status).to eq('ended')
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'lets the same two companies link again after a link ends' do
    link = link!
    post "/api/v1/company_links/#{link.id}/end", headers: h(dealer)
    expect(link.reload.status).to eq('ended')

    again = link!
    expect(again).to be_active
    expect(again.id).not_to eq(link.id)
  end

  it 'opens a link notice on the right page for each side' do
    link = link!
    pl = offer!(link)
    installer_note = Notification.where(recipient: boss, notification_type: 'project_link').last
    expect(installer_note.computed_action_url).to eq('/linked-companies?view=jobs')
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    project.update!(deal_id: nil)
    dealer_note = Notification.where(recipient: dealer, notification_type: 'project_link').last
    expect(dealer_note.computed_action_url).to eq('/linked-companies')
  end
end
