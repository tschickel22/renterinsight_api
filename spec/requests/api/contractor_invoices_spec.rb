# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/private_files_stub'

# E68 step 2: an invoice sent from the contractor portal becomes a draft bill,
# linked to the project and the cost line it pays for.
RSpec.describe 'Contractor portal invoices', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') } # seeds the chart of accounts
  let(:installer) { Contractor.create!(company: company, name: 'Smith Set-Up', email: 'office@smithsetup.example', status: 'active') }
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active', assigned_vendor_id: installer.id) }
  let!(:phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'in_progress') }
  let(:headers) do
    token = JWT.encode({ contractor_ids: [installer.id], primary_contractor_id: installer.id, exp: 1.hour.from_now.to_i },
                       Api::Contractor::BaseController.jwt_secret, 'HS256')
    { 'Authorization' => "Bearer #{token}" }
  end
  let(:pdf) { Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4 invoice'), 'application/pdf', original_filename: 'inv-1042.pdf') }
  let(:path) { "/api/contractor/projects/#{project.id}/invoices" }

  before do
    stub_private_files
    allow(Accounting::BillScanService).to receive(:new).and_raise(Accounting::BillScanService::ScanError, 'not configured')
    allow(ProjectNotificationService).to receive(:announce_invoice_submitted)
  end

  def body = JSON.parse(response.body)

  def submit(**extra)
    post path, headers: headers, params: { file: pdf, amount: '4,850.00', invoice_number: 'INV-1042', phase_id: phase.id }.merge(extra)
  end

  it 'makes a draft bill with the file, a cost line, and tells the dealer' do
    submit

    expect(response).to have_http_status(:created)
    bill = company.bills.last
    expect(bill).to have_attributes(status: 'draft', vendor_id: installer.id, project_id: project.id,
                                    source: 'contractor_portal', reference_number: 'INV-1042', total_amount: 4850)
    expect(bill.journal_entry_id).to be_nil
    expect(bill.attachments.first['url']).to start_with('s3://dt-private-test/bills/')
    expect(bill.bill_line_items.first.chart_of_account.name).to eq('Delivery & Setup Costs')

    item = project.project_cost_items.find_by(bill_id: bill.id)
    expect(item).to have_attributes(amount: 4850, cost_type: 'subcontractor', project_phase_id: phase.id, status: 'pending')
    # Committed until the dealer approves the bill, which approves the line.
    expect(project.reload).to have_attributes(actual_cost: 0, committed_cost: 4850)
    expect(ProjectNotificationService).to have_received(:announce_invoice_submitted).with(bill, installer, project)
    expect(body['invoice']).to include('status_label' => 'Received', 'invoice_number' => 'INV-1042')
  end

  it "pays the dealer's open cost line for this work instead of adding another" do
    line = project.project_cost_items.create!(company_id: company.id, project_phase_id: phase.id, vendor_id: installer.id,
                                              description: 'Set and level', amount: 4500, cost_type: 'subcontractor', status: 'pending')

    submit

    expect(project.project_cost_items.not_deleted.count).to eq(1)
    expect(line.reload).to have_attributes(amount: 4850, bill_id: company.bills.last.id)
    expect(line.metadata['amount_before_invoice']).to eq('4500.0')
  end

  it 'refuses the same invoice number twice' do
    submit
    submit(file: Rack::Test::UploadedFile.new(StringIO.new('%PDF again'), 'application/pdf', original_filename: 'again.pdf'))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq('Invoice INV-1042 was already submitted')
  end

  it 'refuses a project the contractor has no part in' do
    project.update!(assigned_vendor_id: nil)
    submit
    expect(response).to have_http_status(:not_found)
  end

  it 'moves the cost line along with the bill: approved, then paid' do
    submit
    bill = company.bills.last
    item = project.project_cost_items.find_by(bill_id: bill.id)

    bill.update!(status: 'pending')
    expect(item.reload.status).to eq('approved')

    bank = company.chart_of_accounts.find_by(sub_type: 'bank') || company.chart_of_accounts.where(account_type: 'asset').first
    bill.record_payment!(amount: 4850, payment_date: Date.current, chart_of_account_id: bank.id)
    expect(item.reload.status).to eq('paid')

    get path, headers: headers
    expect(body['items'].first).to include('status_label' => 'Paid')
  end

  describe 'cost lines post through bills setting' do
    let(:dealer) do
      User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                   company_id: company.id, role: 'company_admin', status: 'active')
    end
    let(:dealer_headers) do
      { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
    end
    let(:cost_path) { "/api/v1/projects/#{project.id}/cost_items" }

    def add_cost
      post cost_path, headers: dealer_headers,
                      params: { description: 'Skirting', amount: 1200, cost_type: 'subcontractor', contractor_id: installer.id, project_phase_id: phase.id }.to_json
    end

    it 'leaves cost lines as tracking only by default' do
      add_cost
      expect(response).to have_http_status(:created)
      expect(body['bill']).to be_nil
      expect(company.bills.count).to eq(0)
    end

    it 'makes a draft bill for a vendor cost line when turned on, following its amount while a draft' do
      patch '/api/v1/company_settings/project_management', headers: dealer_headers,
            params: { project_management: { cost_lines_post_via_bills: true } }.to_json
      expect(body['project_management']).to include('cost_lines_post_via_bills' => true, 'require_client_approval' => false)

      add_cost
      expect(body['bill']).to include('status' => 'draft', 'source' => 'project_cost_line')

      patch "#{cost_path}/#{body['id']}", headers: dealer_headers, params: { amount: 1350 }.to_json
      expect(company.bills.last.total_amount).to eq(1350)
    end

    it "replaces the cost line's own draft bill instead of billing the work twice" do
      patch '/api/v1/company_settings/project_management', headers: dealer_headers,
            params: { project_management: { cost_lines_post_via_bills: true } }.to_json
      add_cost
      placeholder_id = body['bill']['id']

      post path, headers: headers, params: { file: pdf, amount: '1250', invoice_number: 'INV-77', phase_id: phase.id }

      expect(response).to have_http_status(:created)
      expect(Bill.exists?(placeholder_id)).to be(false)
      expect(project.project_cost_items.not_deleted.count).to eq(1)
      expect(project.project_cost_items.first.bill.source).to eq('contractor_portal')
      expect(company.bills.count).to eq(1)
    end

    it "refuses a phase from another project on a cost line" do
      other = company.projects.create!(name: 'Other', status: 'active')
      other_phase = other.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started')

      post cost_path, headers: dealer_headers,
                      params: { description: 'Skirting', amount: 10, cost_type: 'other', project_phase_id: other_phase.id }.to_json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
