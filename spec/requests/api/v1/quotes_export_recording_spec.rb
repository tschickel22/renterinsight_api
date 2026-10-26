# frozen_string_literal: true

require 'rails_helper'

# The quotes CSV streams straight from its controller, outside the Exporter.
# It still has to leave the same record and watermark as every other export.
RSpec.describe 'GET /api/v1/quotes/export recording', type: :request do
  let(:company) { Company.create!(name: "Quote Export Co #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "qexp-#{SecureRandom.hex(4)}@example.com", first_name: 'Q', last_name: 'X',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  it 'records the export and adds the export_ref column' do
    expect { get '/api/v1/quotes/export', params: { status: 'draft' }, headers: headers }
      .to change { ExportJob.where(company_id: company.id, module_type: 'quotes').count }.by(1)

    expect(response).to have_http_status(:ok)
    job = ExportJob.last
    expect(job.filters).to include('status' => 'draft', 'export_scope' => 'all_matching')
    expect(response.body.lines.first.strip).to end_with('export_ref')
    expect(ActivityLog.where(company_id: company.id, action: 'export_downloaded').count).to eq(1)
  end
end
