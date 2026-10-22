# frozen_string_literal: true

require 'rails_helper'
require_relative '../../../support/private_files_stub'

# E68 step 4: send a phase to several contractors, take their bids in the
# portal or by phone, and award one. The award assigns the phase and adds the
# committed cost line the contractor's invoice later bills against.
RSpec.describe 'Project bids', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:smith) { Contractor.create!(company: company, name: 'Smith Set-Up', email: 'office@smithsetup.example', status: 'active') }
  let(:jones) { Contractor.create!(company: company, name: 'Jones Install', email: 'jones@install.example', status: 'active') }
  let(:phone_only) { Contractor.create!(company: company, name: 'Acme Crane', status: 'active') }
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active', owner: dealer, delivery_city: 'Golden', delivery_state: 'CO') }
  let!(:phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started') }
  let!(:task) { phase.project_phase_tasks.create!(company: company, name: 'Set and level', position: 0) }
  let(:base) { "/api/v1/projects/#{project.id}/bid_requests" }

  def body = JSON.parse(response.body)

  def portal_headers(vendor)
    token = JWT.encode({ contractor_ids: [vendor.id], primary_contractor_id: vendor.id, exp: 1.hour.from_now.to_i },
                       Api::Contractor::BaseController.jwt_secret, 'HS256')
    { 'Authorization' => "Bearer #{token}" }
  end

  def send_request(vendors = [smith, jones, phone_only])
    post base, headers: headers, params: { project_phase_id: phase.id, bids_due_on: (Date.current + 7).iso8601,
                                           vendor_ids: vendors.map(&:id) }.to_json
    expect(response).to have_http_status(:created)
    company.project_bid_requests.last
  end

  def bid_for(request, vendor) = request.bids.find_by!(vendor_id: vendor.id)

  include ActiveJob::TestHelper

  def notices(kind) = enqueued_jobs.select { |j| j[:job] == ProjectBidNoticeJob && j[:args].last == kind }.map { |j| j[:args].first }

  it 'sends a phase to each contractor with the phase and its tasks as the scope' do
    request = send_request

    expect(request).to have_attributes(status: 'open', title: 'Set', project_phase_id: phase.id, created_by_id: dealer.id)
    expect(request.scope).to include('Set', '- Set and level')
    expect(request.bids.pluck(:status).uniq).to eq(['invited'])
    expect(notices('requested')).to match_array(request.bids.pluck(:id))
  end

  it 'refuses a second open request on the same phase, and a contractor from another company' do
    send_request
    post base, headers: headers, params: { project_phase_id: phase.id, vendor_ids: [smith.id] }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('already has open bids')

    other = Contractor.create!(company: create(:company), name: 'Elsewhere', email: 'x@y.example', status: 'active')
    post base, headers: headers, params: { vendor_ids: [other.id] }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq('Pick at least one contractor to ask')
  end

  it 'lets a contractor see only their own bid, bid, revise and ring the dealer' do
    request = send_request
    get '/api/contractor/bids', headers: portal_headers(smith)
    expect(body['items'].size).to eq(1)
    item = body['items'].first
    expect(item).to include('title' => 'Set', 'city' => 'Golden, CO', 'status' => 'invited', 'open' => true)
    expect(item).to include('project_name' => nil) # project names carry the customer's name

    get "/api/contractor/bids/#{bid_for(request, jones).id}", headers: portal_headers(smith)
    expect(response).to have_http_status(:not_found)

    bid = bid_for(request, smith)
    post "/api/contractor/bids/#{bid.id}/submit", headers: portal_headers(smith), params: { amount: '4500', duration_days: 3 }
    expect(response).to have_http_status(:ok)
    expect(bid.reload).to have_attributes(status: 'submitted', amount: 4500, duration_days: 3, entered_by_id: nil)
    expect(Notification.where(notification_type: 'project_bid_submitted', recipient: dealer).last.title).to eq('Bid from Smith Set-Up')

    post "/api/contractor/bids/#{bid.id}/submit", headers: portal_headers(smith), params: { amount: '4300' }
    expect(bid.reload.amount).to eq(4300)
    note = Notification.where(notification_type: 'project_bid_submitted').order(:id).last
    expect(note.title).to eq('Revised bid from Smith Set-Up')
    expect(note.computed_action_url).to be_nil # project has no deal

    post "/api/contractor/bids/#{bid_for(request, jones).id}/decline", headers: portal_headers(jones), params: { notes: 'Booked solid' }
    expect(bid_for(request, jones).status).to eq('declined')
  end

  it 'takes a phone bid from staff and awards it: phase assigned, committed cost line, others told' do
    request = send_request
    post "/api/contractor/bids/#{bid_for(request, smith).id}/submit", headers: portal_headers(smith), params: { amount: '4500' }

    phone = bid_for(request, phone_only)
    post "#{base}/#{request.id}/record_bid", headers: headers, params: { bid_id: phone.id, amount: 3900, notes: 'Called in' }.to_json
    expect(response).to have_http_status(:ok)
    expect(phone.reload).to have_attributes(status: 'submitted', amount: 3900, entered_by_id: dealer.id)
    listed = body['bid_request']['bids']
    expect(listed.first).to include('vendor_name' => 'Acme Crane', 'lowest' => true, 'entered_by_name' => be_present)

    post "#{base}/#{request.id}/award", headers: headers, params: { bid_id: phone.id }.to_json
    expect(response).to have_http_status(:ok)

    expect(request.reload).to have_attributes(status: 'awarded', awarded_bid_id: phone.id, awarded_by_id: dealer.id)
    expect(phase.reload.assigned_vendor_id).to eq(phone_only.id)
    expect(task.contractor_assignments.pluck(:vendor_id)).to eq([phone_only.id])
    cost = project.project_cost_items.find(phone.reload.project_cost_item_id)
    expect(cost).to have_attributes(amount: 3900, status: 'pending', cost_type: 'subcontractor', vendor_id: phone_only.id,
                                    project_phase_id: phase.id, description: 'Bid: Set')
    expect(bid_for(request, smith).status).to eq('not_awarded')
    expect(bid_for(request, jones).status).to eq('invited')
    expect(notices('awarded_elsewhere')).to eq([bid_for(request, smith).id])

    # Bidding is closed now.
    post "/api/contractor/bids/#{bid_for(request, smith).id}/submit", headers: portal_headers(smith), params: { amount: '100' }
    expect(response).to have_http_status(:unprocessable_entity)

    # The winner sees the job under Projects.
    get '/api/contractor/projects', headers: portal_headers(phone_only)
    expect(response.body).to include('Diaz home')
  end

  it "emails a bidder the work and the town, never the project's name" do
    request = send_request([smith])
    allow(CommunicationService).to receive(:send_email)
    ProjectNotificationService.notify_bid_requested(bid_for(request, smith))
    expect(CommunicationService).to have_received(:send_email) do |args|
      expect(args[:subject]).to eq('Bid request: Set in Golden, CO')
      expect(args[:body]).not_to include('Diaz')
    end
  end

  it "bills the winner's portal invoice against the awarded cost line" do
    stub_private_files
    allow(Accounting::BillScanService).to receive(:new).and_raise(Accounting::BillScanService::ScanError, 'not configured')
    allow(ProjectNotificationService).to receive(:announce_invoice_submitted)

    request = send_request([smith])
    bid = bid_for(request, smith)
    post "/api/contractor/bids/#{bid.id}/submit", headers: portal_headers(smith), params: { amount: '4500' }
    post "#{base}/#{request.id}/award", headers: headers, params: { bid_id: bid.id }.to_json

    pdf = Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4 invoice'), 'application/pdf', original_filename: 'inv.pdf')
    post "/api/contractor/projects/#{project.id}/invoices", headers: portal_headers(smith),
                                                            params: { file: pdf, amount: '4500', invoice_number: 'S-1', phase_id: phase.id }
    expect(response).to have_http_status(:created)
    expect(project.project_cost_items.not_deleted.count).to eq(1)
    expect(bid.reload.project_cost_item.bill_id).to eq(company.bills.last.id)
  end

  it 'undoes an award back to the previous owner, but not once the cost is billed' do
    phase.update!(assigned_vendor_id: jones.id)
    request = send_request([smith, jones])
    bid = bid_for(request, smith)
    post "/api/contractor/bids/#{bid.id}/submit", headers: portal_headers(smith), params: { amount: '4500' }
    post "#{base}/#{request.id}/award", headers: headers, params: { bid_id: bid.id, notify_others: false }.to_json
    expect(phase.reload.assigned_vendor_id).to eq(smith.id)
    cost_id = bid.reload.project_cost_item_id

    post "#{base}/#{request.id}/undo_award", headers: headers
    expect(response).to have_http_status(:ok)
    expect(request.reload).to have_attributes(status: 'open', awarded_bid_id: nil)
    expect(bid.reload).to have_attributes(status: 'submitted', project_cost_item_id: nil)
    expect(ProjectCostItem.exists?(cost_id)).to be(false)
    expect(phase.reload.assigned_vendor_id).to eq(jones.id)

    post "#{base}/#{request.id}/award", headers: headers, params: { bid_id: bid.id }.to_json
    bid.reload.project_cost_item.update_columns(status: 'approved')
    post "#{base}/#{request.id}/undo_award", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('already billed')
  end

  it 'cancels an open request and tells those still bidding' do
    request = send_request([smith, jones])
    post "/api/contractor/bids/#{bid_for(request, jones).id}/decline", headers: portal_headers(jones)

    post "#{base}/#{request.id}/cancel", headers: headers
    expect(request.reload.status).to eq('cancelled')
    expect(notices('closed')).to eq([bid_for(request, smith).id])

    get '/api/contractor/bids', headers: portal_headers(smith)
    expect(body['items'].first).to include('status' => 'closed', 'open' => false)
  end

  it "keeps another company's project out of reach" do
    other_project = create(:company).projects.create!(name: 'Not ours', status: 'active')
    get "/api/v1/projects/#{other_project.id}/bid_requests", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'links the bell to the deal Progress tab, and the invoice bell to its bill' do
    deal = company.deals.create!(location: company.locations.first || company.locations.create!(name: 'Main'),
                                 name: 'Diaz home', account: company.accounts.create!(name: 'Diaz'))
    project.update!(deal: deal)
    request = send_request([smith])
    post "/api/contractor/bids/#{bid_for(request, smith).id}/submit", headers: portal_headers(smith), params: { amount: '4500' }
    note = Notification.where(notification_type: 'project_bid_submitted').last
    expect(note.computed_action_url).to eq("/deals/#{deal.id}?tab=progress&projectTab=bids")

    bill_note = Notification.new(notifiable_type: 'Bill', notifiable_id: 42)
    allow(bill_note).to receive(:notifiable).and_return(Object.new)
    expect(bill_note.computed_action_url).to eq('/accounting/bills?billId=42')
  end
end
