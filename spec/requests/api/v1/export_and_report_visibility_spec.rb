# frozen_string_literal: true

require 'rails_helper'

# The Import/Export builder and the report builder read records without going
# through the module's own list, so they used to skip its rules: Import/Export
# access alone exported a whole module, and reports needed no permission at
# all. Both now need the module's read permission and are narrowed to the
# person's locations exactly as the list is (VisibleRecords).
RSpec.describe 'Export and report visibility', type: :request do
  let(:company) do
    Company.create!(name: "Vis-#{SecureRandom.hex(4)}", industry: 'manufactured_housing', use_rbac_system: true)
  end
  let(:mine)   { company.locations.create!(name: 'Mine', timezone: 'America/Denver') }
  let(:theirs) { company.locations.create!(name: 'Theirs', timezone: 'America/Denver') }

  before do
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
  end

  # A location-tier user at `mine` holding exactly the grants named.
  def user_with(grants)
    role = Role.create!(company_id: company.id, key: "r-#{SecureRandom.hex(3)}",
                        name: 'Rep', tier: 'location', active: true)
    all_scope = Scope.find_by!(key: 'all')
    grants.each do |resource, actions|
      Array(actions).each do |action|
        RolePermission.create!(role: role, resource: Resource.find_by!(key: resource),
                               action: Action.find_by!(key: action), scope: all_scope, granted: true)
      end
    end

    user = company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U',
                                 last_name: 'Ser', password: 'Pass1234!', role: 'user')
    user.user_role_assignments.create!(role: role, company_id: company.id, tier: 'location', location_id: mine.id)
    Rails.cache.clear
    user
  end

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  let!(:here)       { company.accounts.create!(name: 'Here', location_id: mine.id) }
  let!(:elsewhere)  { company.accounts.create!(name: 'Elsewhere', location_id: theirs.id) }
  let!(:unassigned) { company.accounts.create!(name: 'Unassigned', location_id: nil) }

  let(:exporter) { user_with('data_import_export' => %w[read create], 'crm' => 'read') }

  describe 'Import/Export builder' do
    def request_export(user)
      post '/api/v1/export_jobs', headers: headers_for(user),
                                  params: { module_type: 'accounts', format: 'csv', acknowledged: true,
                                            selected_fields: %w[name] }
    end

    it "exports only the accounts the person's list shows" do
      request_export(exporter)
      expect(response).to have_http_status(:created)

      job = ExportJob.last
      ImportExport::Exporter.new(job).process!
      expect(job.reload.status).to eq('completed')
      expect(job.row_count).to eq(2) # Here and Unassigned, never Elsewhere
    end

    it 'refuses a module the person cannot read' do
      request_export(user_with('data_import_export' => %w[read create]))

      expect(response).to have_http_status(:forbidden)
      expect(ExportJob.count).to eq(0)
    end

    it 'leaves a company admin unrestricted' do
      admin = company.users.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A',
                                    last_name: 'Dmin', password: 'Pass1234!', role: 'company_admin')
      request_export(admin)

      job = ExportJob.last
      ImportExport::Exporter.new(job).process!
      expect(job.reload.row_count).to eq(3)
    end
  end

  describe 'report builder' do
    def run_report(user, module_key: 'accounts')
      post '/api/v1/reports/run', headers: headers_for(user), as: :json,
                                  params: { module_key: module_key, fields: %w[name], filters: {},
                                            sort_by: 'name', sort_order: 'asc', page: 1, per_page: 50 }
    end

    it "returns only the records the person's list shows" do
      run_report(user_with('crm' => 'read'))

      expect(response).to have_http_status(:ok)
      names = JSON.parse(response.body)['rows'].map { |r| r['name'] }
      expect(names).to contain_exactly('Here', 'Unassigned')
    end

    it 'refuses a module the person cannot read' do
      run_report(user_with('leads' => 'read'))
      expect(response).to have_http_status(:forbidden)

      run_report(user_with('crm' => 'read'), module_key: 'journal_entries')
      expect(response).to have_http_status(:forbidden)
    end

    it 'lists only the modules the person can read' do
      get '/api/v1/reports/modules', headers: headers_for(user_with('crm' => 'read'))

      keys = JSON.parse(response.body).map { |m| m['key'] }
      expect(keys).to include('accounts', 'contacts')
      expect(keys).not_to include('journal_entries', 'bank_transactions', 'bills', 'invoices')
    end
  end
end
