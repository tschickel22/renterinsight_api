# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/private_files_stub'

# Project work is not limited to vendors typed "contractor": a supplier or
# service provider given a task can sign into the portal, see the project, and
# send a bill for it, including after the project is completed.
RSpec.describe 'Project work for any vendor type', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:dealer_headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:plumber) do
    company.vendors.create!(name: 'Rapid Plumbing', vendor_type: 'service_provider', email: 'office@rapidplumbing.example', status: 'active')
  end
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active') }
  let!(:phase) { project.project_phases.create!(company: company, name: 'Utilities', position: 0, status: 'in_progress') }
  let!(:task) { phase.project_phase_tasks.create!(company: company, name: 'Water hookup', position: 0) }
  let(:pdf) { Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4 invoice'), 'application/pdf', original_filename: 'rp-77.pdf') }

  before do
    stub_private_files
    allow(Accounting::BillScanService).to receive(:new).and_raise(Accounting::BillScanService::ScanError, 'not configured')
    allow(ProjectNotificationService).to receive(:announce_invoice_submitted)
    allow(ContractorAssignmentNotifierJob).to receive_message_chain(:set, :perform_later)
    allow(CommunicationService).to receive(:send_email)
  end

  def body = JSON.parse(response.body)

  def portal_headers
    post '/api/contractor/sessions/magic_link', params: { email: plumber.email }
    post '/api/contractor/sessions/verify', params: { token: plumber.reload.portal_access_token }
    expect(response).to have_http_status(:ok)
    { 'Authorization' => "Bearer #{body['token']}" }
  end

  it 'assigns a service provider to a task, and they bill the completed project from the portal' do
    post "/api/v1/projects/#{project.id}/assign_phase_task_contractor", headers: dealer_headers,
         params: { phase_id: phase.id, task_id: task.id, contractor_id: plumber.id }.to_json
    expect(response).to have_http_status(:success)
    assignment = task.contractor_assignments.sole
    expect(assignment.contractor).to have_attributes(id: plumber.id, vendor_type: 'service_provider')

    project.update!(status: 'completed')
    headers = portal_headers

    get '/api/contractor/projects', headers: headers
    expect(body['items'].map { |p| p['id'] }).to include(project.id)

    post "/api/contractor/projects/#{project.id}/invoices", headers: headers,
         params: { file: pdf, amount: '640.00', invoice_number: 'RP-77', phase_id: phase.id }
    expect(response).to have_http_status(:created)
    expect(company.bills.last).to have_attributes(vendor_id: plumber.id, project_id: project.id, status: 'draft',
                                                 source: 'contractor_portal', total_amount: 640)
  end

  it 'lets a supplier own a phase' do
    supplier = company.vendors.create!(name: 'Coastal Supply', vendor_type: 'supplier', status: 'active')
    post "/api/v1/projects/#{project.id}/assign_phase", headers: dealer_headers,
         params: { phase_id: phase.id, assigned_vendor_id: supplier.id, apply_to_tasks: false }.to_json

    expect(response).to have_http_status(:ok)
    expect(phase.reload.assigned_vendor_id).to eq(supplier.id)
  end

  it 'still refuses an inactive vendor' do
    plumber.update!(status: 'inactive')
    post "/api/v1/projects/#{project.id}/assign_phase", headers: dealer_headers,
         params: { phase_id: phase.id, assigned_vendor_id: plumber.id, apply_to_tasks: false }.to_json

    expect(response).to have_http_status(:unprocessable_entity)
  end
end
