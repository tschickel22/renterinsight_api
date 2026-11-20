# frozen_string_literal: true

require 'rails_helper'
require_relative '../../../support/private_files_stub'

# E107: contractors accept with a start date, work days and notes; a bid's
# dates land on the phase it wins. Dates the dealer already set wait for the
# dealer to confirm.
RSpec.describe 'Contractor dates', type: :request do
  include ActiveJob::TestHelper

  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:crew) { Contractor.create!(company: company, name: 'Rocky Mountain Set Crew', email: 'crew@rmset.example', status: 'active') }
  let(:project) { company.projects.create!(name: 'Garcia set', status: 'active', owner: dealer) }
  let!(:phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started') }
  let!(:task) { phase.project_phase_tasks.create!(company: company, name: 'Set and level', position: 0) }
  let(:assignment) { task.contractor_assignments.create!(company: company, contractor: crew, status: 'assigned', assigned_at: Time.current) }

  def body = JSON.parse(response.body)

  def portal_headers(vendor)
    token = JWT.encode({ contractor_ids: [vendor.id], primary_contractor_id: vendor.id, exp: 1.hour.from_now.to_i },
                       Api::Contractor::BaseController.jwt_secret, 'HS256')
    { 'Authorization' => "Bearer #{token}" }
  end

  def accept(**params)
    patch "/api/contractor/tasks/#{assignment.id}/update_status", headers: portal_headers(crew),
                                                                  params: { status: 'accepted' }.merge(params)
  end

  describe 'work days' do
    it 'counts Monday to Friday, and a weekend start from the Monday after' do
      expect(ContractorDates.end_date(Date.new(2026, 12, 1), 6)).to eq(Date.new(2026, 12, 8)) # Tue + 6 = next Tue
      expect(ContractorDates.end_date(Date.new(2026, 11, 30), 1)).to eq(Date.new(2026, 11, 30))
      expect(ContractorDates.end_date(Date.new(2026, 11, 28), 2)).to eq(Date.new(2026, 12, 1)) # Saturday start
    end
  end

  it 'puts the dates straight on a task that had none, with the notes on its log' do
    accept(start_date: '2026-12-01', work_days: 3, accept_notes: 'Need the pad graded first')
    expect(response).to have_http_status(:ok), response.body
    expect(task.reload).to have_attributes(estimated_start_date: Date.new(2026, 12, 1), estimated_completion_date: Date.new(2026, 12, 3))
    expect(body).to include('status' => 'accepted', 'dates_status' => 'applied', 'accept_notes' => 'Need the pad graded first')
    expect(AssignmentWorkLog.where(contractor_assignment: assignment, log_type: 'note').pluck(:note)).to include('Need the pad graded first')
  end

  it 'holds dates for the dealer when the task already has some, then confirm applies them' do
    task.update!(estimated_start_date: Date.new(2026, 11, 30), estimated_completion_date: Date.new(2026, 12, 2))
    accept(start_date: '2026-12-03', work_days: 2)
    expect(body['dates_status']).to eq('pending')
    expect(task.reload.estimated_start_date).to eq(Date.new(2026, 11, 30))
    item = company.review_items.open.find_by(kind: 'contractor_dates')
    expect(item.title).to include('Rocky Mountain Set Crew proposes Dec 3 to Dec 4')

    post "/api/v1/contractor_assignments/#{assignment.id}/confirm_dates", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(task.reload).to have_attributes(estimated_start_date: Date.new(2026, 12, 3), estimated_completion_date: Date.new(2026, 12, 4))
    expect(item.reload.status).to eq('closed')
  end

  it 'keeps the dealer dates when turned down' do
    task.update!(estimated_start_date: Date.new(2026, 11, 30))
    accept(start_date: '2026-12-03', work_days: 2)
    post "/api/v1/contractor_assignments/#{assignment.id}/decline_dates", headers: headers
    expect(body['dates_status']).to eq('declined')
    expect(task.reload.estimated_start_date).to eq(Date.new(2026, 11, 30))
  end

  it 'gives dates for the whole phase when the contractor runs it' do
    phase.update!(assigned_vendor_id: crew.id)
    get "/api/contractor/tasks/#{assignment.id}", headers: portal_headers(crew)
    expect(body['runs_whole_phase']).to be(true)

    accept(start_date: '2026-12-01', work_days: 6, dates_for: 'phase')
    expect(phase.reload).to have_attributes(estimated_start_date: Date.new(2026, 12, 1), estimated_completion_date: Date.new(2026, 12, 8))
  end

  it 'still accepts with no dates, as before' do
    accept
    expect(response).to have_http_status(:ok)
    expect(assignment.reload.status).to eq('accepted')
    expect(assignment.dates_status).to be_nil
  end

  describe 'a bid award' do
    let(:base) { "/api/v1/projects/#{project.id}/bid_requests" }

    def awarded_with(**params)
      post base, headers: headers, params: { project_phase_id: phase.id, vendor_ids: [crew.id] }.to_json
      request = company.project_bid_requests.last
      bid = request.bids.find_by!(vendor_id: crew.id)
      post "/api/contractor/bids/#{bid.id}/submit", headers: portal_headers(crew),
                                                     params: { amount: '3800', can_start_on: '2026-12-01', duration_days: 6 }
      post "#{base}/#{request.id}/award", headers: headers, params: { bid_id: bid.id }.merge(params).to_json
      expect(response).to have_http_status(:ok), response.body
    end

    it 'puts the bid dates on a phase with none' do
      awarded_with
      expect(phase.reload).to have_attributes(estimated_start_date: Date.new(2026, 12, 1), estimated_completion_date: Date.new(2026, 12, 8))
    end

    it 'leaves dates the dealer set unless the award says to use the bid dates' do
      phase.update!(estimated_start_date: Date.new(2026, 11, 24))
      awarded_with
      expect(phase.reload.estimated_start_date).to eq(Date.new(2026, 11, 24))
    end

    it 'uses the bid dates over the dealer dates when asked' do
      phase.update!(estimated_start_date: Date.new(2026, 11, 24))
      awarded_with(apply_dates: true)
      expect(phase.reload.estimated_start_date).to eq(Date.new(2026, 12, 1))
    end
  end
end
