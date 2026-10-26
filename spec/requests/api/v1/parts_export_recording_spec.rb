# frozen_string_literal: true

require 'rails_helper'

# The parts CSV streams from its own controller, outside the Exporter. It
# still has to leave the same record and watermark as every other export.
RSpec.describe 'GET /api/v1/parts/export recording', type: :request do
  let(:company) { Company.create!(name: "Parts Export Co #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "pexp-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'X',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  before do
    company.parts.create!(sku: 'SKU-1', name: 'Widget', default_cost: 2, list_price: 5)
  end

  %w[all_locations current_location].each do |export_type|
    it "records the #{export_type} export and stamps every row" do
      expect { get '/api/v1/parts/export', params: { export_type: export_type, search: 'Wid' }, headers: headers }
        .to change { ExportJob.where(company_id: company.id, module_type: 'parts').count }.by(1)

      expect(response).to have_http_status(:ok)
      job = ExportJob.last
      expect(job.row_count).to eq(1)
      expect(job.filters).to include('search' => 'Wid', 'export_type' => export_type)

      rows = CSV.parse(response.body)
      header = rows.find { |r| r.first == 'SKU' }
      expect(header.last).to eq('export_ref')
      part_row = rows.find { |r| r.first == 'SKU-1' }
      expect(part_row.last).to eq(job.watermark_token)
    end
  end
end
