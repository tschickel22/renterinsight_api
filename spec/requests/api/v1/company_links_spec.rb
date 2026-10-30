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
  # Inviting needs the Linked Installers add-on, and the invited email must
  # already be an admin here.
  let!(:linked_addon) { TenantModuleOverride.create!(company: dealer_co, module_key: 'management.linked_companies', is_enabled: true) }
  before { boss }

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
    expect(Notification.where(recipient: boss, notification_type: 'project_link_request').count).to eq(1)
    expect(Notification.where(company_id: dealer_co.id, notification_type: 'project_link_request')).to be_empty
    # Waits in the installer's Review Updates, not the dealer's.
    expect(installer_co.review_items.open.pluck(:kind)).to eq(['link_request'])
    expect(dealer_co.review_items).to be_empty

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
    expect(installer_co.review_items.open).to be_empty
    expect(installer_co.review_items.closed.first.resolution).to eq('accepted')
  end

  it 'refuses an invite to an email that is not an admin on the platform, and sends nothing' do
    contractor = Contractor.create!(company: dealer_co, name: 'Joe Setter', email: 'joe@setter.example', status: 'active')
    expect {
      post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: contractor.id, email: 'joe@setter.example' }.to_json
    }.not_to have_enqueued_job(CompanyLinkInviteEmailJob)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('not an admin of a company', 'assign them on the project instead')

    # A user who is not an admin does not count either.
    User.create!(email: 'crew@install.example', first_name: 'C', last_name: 'D', password: 'Pass1234!', company_id: installer_co.id, role: 'sales', status: 'active')
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: contractor.id, email: 'crew@install.example' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(CompanyLink.count).to eq(0)
  end

  it 'needs the Linked Installers add-on to invite, and gives the installer the page while linked' do
    expect(dealer_co.has_module?('management.linked_companies')).to be(true)
    expect(installer_co.has_module?('management.linked_companies')).to be(false)

    linked_addon.update!(is_enabled: false)
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: boss.email }.to_json
    expect(response).to have_http_status(:forbidden)
    get '/api/v1/company_links', headers: h(dealer)
    expect(body['can_invite']).to be(false)
    linked_addon.update!(is_enabled: true)

    link = link!
    expect(Company.find(installer_co.id).has_module?('management.linked_companies')).to be(true)
    expect(ModuleAccessService.new(installer_co).enabled_modules).to include('management.linked_companies')
    # The installer sees its jobs but can't invite installers of its own.
    get '/api/v1/company_links', headers: h(boss)
    expect(body['can_invite']).to be(false)
    post '/api/v1/company_links', headers: h(boss), params: { vendor_id: vendor.id, email: dealer.email }.to_json
    expect(response).to have_http_status(:forbidden)

    post "/api/v1/company_links/#{link.id}/end", headers: h(dealer), params: {}.to_json
    expect(Company.find(installer_co.id).has_module?('management.linked_companies')).to be(false)
  end

  it 'sends a platform-branded invite with a link straight to the Links tab' do
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: 'boss@install.example' }.to_json
    sent = nil
    allow(CommunicationService).to receive(:send_email) { |**kw| sent = kw }
    CompanyLinkNotifier.invite_email(CompanyLink.find(body.dig('company_link', 'id')))

    expect(sent[:to]).to eq('boss@install.example')
    expect(sent[:body]).to include('/linked-companies?view=links', 'Review the invitation', Brand.current.name)
    expect(sent[:body]).to include('invited this address to link companies')
    expect(sent[:body]).not_to match(/[–—]/)
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
    # The deal's price and the dealer's costs never cross. The price agreed
    # between the two companies (step 6) does.
    expect(job.keys.grep(/price|gross|cost/) - %w[price_source price_lines price_agreed]).to be_empty
    expect(job.to_s).not_to include('deal_price', 'sale_price', 'front_gross')

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
    # The installer hears about it (E87), on its own copy of the phase.
    moved = installer_co.review_items.open.find_by(kind: 'date_changed', subject: iph)
    expect(moved).to have_attributes(from_name: 'Summit Homes', needs_action: false)
    expect(moved.detail).to include('Nov 20, 2026')
    expect(Notification.where(company_id: installer_co.id, notification_type: 'project_date_changed', recipient: boss)).to exist

    # And the other way: the installer moves the finish date, the dealer is told.
    perform_enqueued_jobs { iph.reload.update!(estimated_completion_date: Date.new(2026, 11, 24)) }
    expect(set_phase.reload.estimated_completion_date).to eq(Date.new(2026, 11, 24))
    expect(dealer_co.review_items.open.find_by(kind: 'date_changed', subject: set_phase)).to have_attributes(from_name: 'Summit Install')
    expect(Notification.where(company_id: dealer_co.id, notification_type: 'project_date_changed', recipient: dealer)).to exist

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
    je = JournalEntry.find_by(company_id: installer_co.id, source_entity_type: 'Invoice', source_entity_id: pl.installer_invoice_id)
    expect(je).to be_present
    # The revenue is the installer's job's, so its profit report shows it beside the job's costs.
    revenue = je.journal_entry_lines.select { |l| l.credit_amount.positive? && l.chart_of_account.account_type == 'revenue' }
    expect(revenue.map(&:project_id)).to eq([ip.id])
    ip.project_cost_items.create!(company_id: installer_co.id, cost_type: 'subcontractor', description: 'Set crew',
                                  amount: 3000, quantity: 1, unit_price: 3000, status: 'approved')
    row = Reports::ProjectJobCostReportService.new(installer_co).profitability[:projects].find { |r| r[:id] == ip.id }
    expect(row).to include(revenue_from: 'invoices', sale_price: 4500.0, job_cost: 3000.0, after_job_cost: 1500.0,
                           margin: 33.3, received: 0.0, owed: 4500.0)
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
    expect(Notification.where(recipient: dealer, notification_type: 'project_job_answered').last.message).to include('Booked that week')
    # The offer closed on the installer's side; the answer is an FYI on the dealer's.
    expect(installer_co.review_items.where(kind: 'job_offered', subject: pl).first.status).to eq('closed')
    expect(dealer_co.review_items.open.where(kind: 'job_answered').first).to have_attributes(needs_action: false, project_id: project.id)

    whole = offer!(link, phase: nil, fee: nil)
    expect(project.reload.assigned_vendor_id).to eq(vendor.id)
    post "/api/v1/project_links/#{whole.id}/cancel", headers: h(dealer)
    expect(whole.reload.status).to eq('cancelled')
    expect(project.reload.assigned_vendor_id).to eq(crew.id)
    expect(finish_phase.reload.assigned_vendor_id).to eq(crew.id)
    expect(set_phase.reload.assigned_vendor_id).to be_nil
  end

  it "closes the installer's copy of a job the dealer takes back" do
    link = link!
    pl = offer!(link, phase: set_phase, fee: 900)
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    copy = pl.reload.installer_project
    post "/api/v1/project_links/#{pl.id}/cancel", headers: h(dealer)
    expect(copy.reload.status).to eq('cancelled')

    # Money already spent on it keeps it on the installer's profit report.
    pl2 = offer!(link, phase: finish_phase, fee: 500)
    post "/api/v1/project_links/#{pl2.id}/accept", headers: h(boss)
    copy2 = pl2.reload.installer_project
    copy2.project_cost_items.create!(company_id: installer_co.id, cost_type: 'subcontractor', description: 'Crane',
                                     amount: 300, quantity: 1, unit_price: 300, date: Date.current, status: 'approved')
    post "/api/v1/project_links/#{pl2.id}/cancel", headers: h(dealer)
    expect(copy2.reload.status).to eq('on_hold')
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

  it 'hands several phases across for one fee' do
    link = link!
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_ids: [finish_phase.id, set_phase.id], fee: 7000 }.to_json
    expect(response).to have_http_status(:created), response.body
    expect(body.dig('project_link', 'scope_label')).to eq('Set and Finish')
    expect(body.dig('project_link', 'phase_ids')).to eq([set_phase.id, finish_phase.id])
    pl = ProjectLink.find(body.dig('project_link', 'id'))
    expect([set_phase.reload, finish_phase.reload].map(&:assigned_vendor_id)).to all(eq(vendor.id))
    expect(project.reload.assigned_vendor_id).to be_nil
    expect(pl.dealer_cost_item.amount).to eq(7000)
    # The fee is committed, not spent: it counts against the budget, not actual cost.
    project.update!(budget_amount: 10_000)
    expect(project.reload).to have_attributes(actual_cost: 0, committed_cost: 7000, budget_variance: 3000)

    # Either phase is now taken.
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_id: finish_phase.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    expect(pl.reload.installer_project.name).to eq('Maria Diaz - Set and Finish')
    expect(pl.installer_project.project_phases.order(:position).pluck(:name)).to eq(%w[Set Finish])

    allow(ProjectNotificationService).to receive(:notify_phase_change)
    ip = pl.installer_project
    perform_enqueued_jobs { ip.project_phases.order(:position).each { |ph| ip.set_phase_status!(ph.reload, 'completed') } }
    expect([set_phase.reload, finish_phase.reload].map(&:status)).to all(eq('completed'))
    expect(pl.reload.status).to eq('done')

    # A phase on another project is refused.
    other = dealer_co.projects.create!(name: 'Other', status: 'active', owner: dealer)
    stray = other.project_phases.create!(company: dealer_co, name: 'Stray', position: 0, status: 'not_started')
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_ids: [stray.id] }.to_json
    expect(response).to have_http_status(:not_found)
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
    installer_note = Notification.where(recipient: boss, notification_type: 'project_job_offered').last
    expect(installer_note.computed_action_url).to eq('/linked-companies?view=jobs')
    post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss)
    project.update!(deal_id: nil)
    dealer_note = Notification.where(recipient: dealer, notification_type: 'project_job_answered').last
    expect(dealer_note.computed_action_url).to eq("/deals/projects/#{project.id}")
  end
end
