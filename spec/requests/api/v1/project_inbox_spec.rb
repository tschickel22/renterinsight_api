# frozen_string_literal: true

require 'rails_helper'
require_relative '../../../support/private_files_stub'

# E87: Review Updates lists project work waiting on someone, closes it when the
# work is done wherever that happens, and each notice reaches people by email
# and text as their Notification Center switches allow. Also the bid fixes
# from the E68 test run: an award note for the winner, a reason before staff
# change a contractor's own bid, files with a bid, and Bids & Quotes.
RSpec.describe 'Project inbox and bids', type: :request do
  include ActiveJob::TestHelper

  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:dealer) { user!(role: 'company_admin', first: 'Dana') }
  let(:rep) { user!(role: 'company_admin', first: 'Rico') }
  let(:smith) { Contractor.create!(company: company, name: 'Smith Set-Up', email: 'office@smithsetup.example', status: 'active') }
  let(:jones) { Contractor.create!(company: company, name: 'Jones Install', email: 'jones@install.example', status: 'active') }
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active', owner: dealer) }
  let!(:phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started') }
  let!(:task) { phase.project_phase_tasks.create!(company: company, name: 'Set and level', position: 0) }

  def user!(role:, first:)
    User.create!(email: "#{first.downcase}-#{SecureRandom.hex(3)}@example.com", first_name: first, last_name: 'S',
                 password: 'Pass1234!', company_id: company.id, role: role, status: 'active')
  end

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: user.company_id)}", 'Content-Type' => 'application/json' }

  def portal(vendor)
    token = JWT.encode({ contractor_ids: [vendor.id], primary_contractor_id: vendor.id, exp: 1.hour.from_now.to_i },
                       Api::Contractor::BaseController.jwt_secret, 'HS256')
    { 'Authorization' => "Bearer #{token}" }
  end

  def body = JSON.parse(response.body)

  def send_request(vendors = [smith, jones])
    post "/api/v1/projects/#{project.id}/bid_requests", headers: h(dealer),
         params: { project_phase_id: phase.id, vendor_ids: vendors.map(&:id) }.to_json
    expect(response).to have_http_status(:created), response.body
    company.project_bid_requests.last
  end

  def bid_for(request, vendor) = request.bids.find_by!(vendor_id: vendor.id)

  def portal_bid(request, vendor, amount)
    post "/api/contractor/bids/#{bid_for(request, vendor).id}/submit", headers: portal(vendor), params: { amount: amount }
    expect(response).to have_http_status(:ok), response.body
  end

  def notice_jobs(kind) = enqueued_jobs.select { |j| j[:job] == ProjectBidNoticeJob && j[:args].last == kind }.map { |j| j[:args].first }

  it 'keeps one row per bid request in Review Updates until it is awarded, and tells the winner with the note' do
    request = send_request
    portal_bid(request, smith, '4500')
    portal_bid(request, jones, '4200')

    items = company.review_items.open.where(kind: 'bid_received')
    expect(items.count).to eq(1)
    expect(items.first).to have_attributes(subject: request, needs_action: true, assigned_user_id: dealer.id, project_id: project.id)
    expect(items.first.detail).to include('2 bids in', 'Low bid $4,200.00 from Jones Install')
    # Email and text go out in the background, per the person's switches.
    expect(enqueued_jobs.count { |j| j[:job] == ProjectNoticeDeliveryJob }).to eq(2)

    get '/api/v1/review_items/counts', headers: h(dealer)
    expect(body).to include('mine' => 1, 'all' => 1)
    get '/api/v1/review_items/counts', headers: h(rep)
    expect(body).to include('mine' => 0, 'all' => 1)

    post "/api/v1/projects/#{project.id}/bid_requests/#{request.id}/award", headers: h(dealer),
         params: { bid_id: bid_for(request, jones).id, note: 'Start Monday, gate code 4411' }.to_json
    expect(response).to have_http_status(:ok), response.body
    expect(request.reload.award_note).to eq('Start Monday, gate code 4411')
    expect(items.first.reload).to have_attributes(status: 'closed', resolution: 'awarded', resolved_by_id: dealer.id)
    expect(notice_jobs('awarded')).to eq([bid_for(request, jones).id])
    expect(notice_jobs('awarded_elsewhere')).to eq([bid_for(request, smith).id])

    post "/api/v1/projects/#{project.id}/bid_requests/#{request.id}/undo_award", headers: h(dealer)
    expect(company.review_items.open.where(kind: 'bid_received').count).to eq(1)

    post "/api/v1/projects/#{project.id}/bid_requests/#{request.id}/cancel", headers: h(dealer), params: { notify: false }.to_json
    expect(company.review_items.open).to be_empty
  end

  it 'emails the winner what they won, with the note' do
    request = send_request([smith])
    portal_bid(request, smith, '4500')
    request.update!(award_note: 'Gate code 4411')
    bid_for(request, smith).update!(status: 'awarded')
    allow(CommunicationService).to receive(:send_email)

    ProjectNotificationService.notify_bid_awarded(bid_for(request, smith))

    expect(CommunicationService).to have_received(:send_email).with(
      hash_including(to: 'office@smithsetup.example', subject: 'You got the job: Set', body: include('Gate code 4411', '$4,500.00'))
    )
  end

  it "asks for a reason before staff change a contractor's own bid, keeps it, and tells the contractor" do
    request = send_request([smith])
    portal_bid(request, smith, '4500')
    url = "/api/v1/projects/#{project.id}/bid_requests/#{request.id}/record_bid"
    bid = bid_for(request, smith)

    post url, headers: h(dealer), params: { bid_id: bid.id, amount: '4000' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include("Say why you're changing it")
    expect(bid.reload.amount).to eq(4500)

    post url, headers: h(dealer), params: { bid_id: bid.id, amount: '4000', reason: 'Agreed by phone without skirting' }.to_json
    expect(response).to have_http_status(:ok), response.body
    bid.reload
    expect(bid.amount).to eq(4000)
    expect(bid.entered_by_id).to be_nil # still the contractor's bid
    expect(bid.history.last).to include('reason' => 'Agreed by phone without skirting', 'by_id' => dealer.id,
                                         'from' => { 'amount' => '4500.0' }, 'to' => { 'amount' => '4000.0' })
    expect(notice_jobs('changed_by_dealer')).to eq([bid.id])
    json_bid = body.dig('bid_request', 'bids').first
    expect(json_bid).to include('contractor_entered' => true)
    expect(json_bid['history'].size).to eq(1)

    # Saving it again unchanged needs no reason; a phone bid never does.
    post url, headers: h(dealer), params: { bid_id: bid.id, amount: '4000' }.to_json
    expect(response).to have_http_status(:ok)
    phone = send_request_for_phone
    post "/api/v1/projects/#{project.id}/bid_requests/#{phone.id}/record_bid", headers: h(dealer),
         params: { bid_id: phone.bids.first.id, amount: '3900' }.to_json
    expect(response).to have_http_status(:ok)
    post "/api/v1/projects/#{project.id}/bid_requests/#{phone.id}/record_bid", headers: h(dealer),
         params: { bid_id: phone.bids.first.id, amount: '3800' }.to_json
    expect(response).to have_http_status(:ok)
  end

  def send_request_for_phone
    other = project.project_phases.create!(company: company, name: 'Finish', position: 1, status: 'not_started')
    post "/api/v1/projects/#{project.id}/bid_requests", headers: h(dealer),
         params: { project_phase_id: other.id, vendor_ids: [jones.id] }.to_json
    company.project_bid_requests.last
  end

  it 'takes files with a bid, keeps them on the project, and shows them to both sides' do
    stub_private_files
    request = send_request([smith])
    bid = bid_for(request, smith)
    file = Rack::Test::UploadedFile.new(StringIO.new('%PDF quote'), 'application/pdf', original_filename: 'quote.pdf')

    post "/api/contractor/bids/#{bid.id}/files", headers: portal(smith), params: { file: file }
    expect(response).to have_http_status(:created), response.body
    expect(body.dig('bid', 'files').map { |f| f['name'] }).to eq(['quote.pdf'])
    doc = project.project_documents.last
    expect(doc).to have_attributes(category: 'bid', documentable: phase)

    get "/api/v1/projects/#{project.id}/bid_requests", headers: h(dealer)
    expect(body['bid_requests'].first['bids'].first['files'].first['name']).to eq('quote.pdf')

    delete "/api/contractor/bids/#{bid.id}/files/#{doc.id}", headers: portal(smith)
    expect(response).to have_http_status(:ok)
    expect(doc.reload.is_deleted).to be(true)
  end

  it 'lists every bid request on Bids & Quotes by stage, with a badge for those ready to award' do
    ready = send_request([smith])
    portal_bid(ready, smith, '4500')
    other = project.project_phases.create!(company: company, name: 'Finish', position: 1, status: 'not_started')
    post "/api/v1/projects/#{project.id}/bid_requests", headers: h(dealer), params: { project_phase_id: other.id, vendor_ids: [jones.id] }.to_json

    get '/api/v1/bids_board', headers: h(dealer)
    expect(response).to have_http_status(:ok), response.body
    stages = body['outgoing'].to_h { |r| [r['phase_name'], r['stage']] }
    expect(stages).to eq('Set' => 'ready', 'Finish' => 'waiting')
    expect(body['outgoing'].first).to include('project_name' => 'Diaz home', 'low_bid' => 4500.0, 'responses' => 1, 'invited' => 1)
    expect(body.dig('counts', 'outgoing')).to include('ready' => 1, 'waiting' => 1)

    get '/api/v1/bids_board/counts', headers: h(dealer)
    expect(body).to include('ready' => 1, 'total' => 1)
  end

  it 'lists a contractor invoice until its bill is approved' do
    bill = company.bills.create!(vendor_id: smith.id, bill_number: 'B-1', bill_date: Date.current, due_date: Date.current + 30,
                                 status: 'draft', total_amount: 4850, subtotal: 4850, project_id: project.id)
    ProjectNotificationService.announce_invoice_submitted(bill, smith, project)
    item = company.review_items.open.find_by!(kind: 'contractor_invoice')
    expect(item).to have_attributes(subject: bill, assigned_user_id: dealer.id, link: "/accounting/bills?billId=#{bill.id}")

    bill.update!(status: 'pending')
    expect(item.reload).to have_attributes(status: 'closed', resolution: 'approved')
  end

  it 'tells an employee given a phase, once, and not someone who gave it to themselves' do
    ProjectAssignmentService.new(project, actor: dealer).assign_phase(phase, { user: rep }, apply_to_tasks: true)
    note = Notification.find_by!(recipient: rep, notification_type: 'project_assigned')
    expect(note.message).to include('You were assigned Set on Diaz home by Dana S')
    item = company.review_items.open.find_by!(kind: 'assigned')
    expect(item).to have_attributes(assigned_user_id: rep.id, needs_action: false, project_phase_id: phase.id)

    ProjectAssignmentService.new(project, actor: dealer).assign_project({ user: dealer }, apply_to_phases: false)
    expect(Notification.where(recipient: dealer, notification_type: 'project_assigned')).to be_empty

    # FYI items close when seen, and can be reopened.
    post "/api/v1/review_items/#{item.id}/seen", headers: h(rep)
    expect(item.reload).to have_attributes(status: 'closed', resolution: 'seen')
    post "/api/v1/review_items/#{item.id}/reopen", headers: h(rep)
    expect(item.reload.status).to eq('open')
  end

  it 'notifies the default owners of a project built from a template' do
    template = company.project_templates.create!(name: 'Standard', is_active: true, default_assigned_to_id: rep.id,
                                                 default_vendor_id: smith.id)
    template.project_template_phases.create!(name: 'Set', position: 0)
    allow(ProjectNotificationService).to receive(:notify_contractor_owner_assigned)

    built = template.create_project!(company: company, created_by: dealer)

    expect(Notification.find_by(recipient: rep, notification_type: 'project_assigned').message).to include(built.name)
    # A phase with no tasks: the contractor gets the owner notice, not a task batch.
    expect(ProjectNotificationService).to have_received(:notify_contractor_owner_assigned).with(smith, built, phase: nil)
  end

  it 'completes the open tasks with the phase when asked' do
    second = phase.project_phase_tasks.create!(company: company, name: 'Tie down', position: 1)
    post "/api/v1/projects/#{project.id}/set_phase_status", headers: h(dealer),
         params: { phase_id: phase.id, status: 'completed', close_open_tasks: true }.to_json
    expect(response).to have_http_status(:ok), response.body
    expect([task.reload.status, second.reload.status]).to eq(%w[completed completed])
  end

  it 'leaves tasks open when completing the phase without asking' do
    post "/api/v1/projects/#{project.id}/set_phase_status", headers: h(dealer),
         params: { phase_id: phase.id, status: 'completed' }.to_json
    expect(task.reload.status).to eq('pending')
  end

  it 'says which contractor cannot be emailed when sending assignment notices' do
    CampaignSuppression.create!(company_id: company.id, email_address: 'office@smithsetup.example', reason: 'bounce_hard')
    task.contractor_assignments.create!(contractor: smith, company: company, status: 'assigned', assigned_at: Time.current)

    post "/api/v1/projects/#{project.id}/flush_assignment_notifications", headers: h(dealer)
    expect(body['undeliverable'].first).to include('name' => 'Smith Set-Up')
    expect(body['undeliverable'].first['reason']).to include('bounced')
  end

  it 'shows untemplated projects on the All Projects grid by their own phase names' do
    get '/api/v1/projects/grid', headers: h(dealer), params: { template_id: 'none' }
    expect(response).to have_http_status(:ok), response.body
    expect(body['template']['phases'].map { |p| p['name'] }).to eq(['Set'])
    expect(body['projects'].map { |p| p['id'] }).to eq([project.id])
  end

  it 'reminds the owner once about an action item that has waited a day' do
    item = ProjectNotices.open!(company: company, kind: 'change_order', subject: phase, title: 'Change order from Schick: $500',
                                project: project, assigned_user: rep)
    allow(NotificationService).to receive(:create).and_call_original

    ReviewItemNudgeJob.perform_now
    expect(Notification.where(notification_type: 'project_review_nudge')).to be_empty

    item.update_columns(created_at: 2.days.ago)
    ReviewItemNudgeJob.perform_now
    ReviewItemNudgeJob.perform_now
    notes = Notification.where(notification_type: 'project_review_nudge')
    expect(notes.map(&:recipient_id)).to eq([rep.id])
    expect(notes.first.message).to include('Change order from Schick: $500')
  end

  it 'defaults new project notices to email and text, and lists them under Projects' do
    pref = NotificationPreference.get_or_create_for(rep, :project_job_offered)
    expect(pref).to have_attributes(category: 'projects', email_enabled: true, sms_enabled: true)
    expect(NotificationPreference.get_or_create_for(rep, :project_job_taken_back).sms_enabled).to be(false)
  end
end
