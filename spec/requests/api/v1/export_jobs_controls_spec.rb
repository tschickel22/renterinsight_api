# frozen_string_literal: true

require 'rails_helper'

# The export endpoint used to accept any format, any field, any number of
# times, and left no audit trail. These are the gates that changed that.
RSpec.describe 'Api::V1 ExportJobs controls', type: :request do
  let(:company) { Company.create!(name: "Export Co #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "exp-#{SecureRandom.hex(4)}@example.com", first_name: 'E', last_name: 'X',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  def allow_json!
    Setting.set(ImportExport::ExportPolicy::SETTING_SCOPE, company.id,
                ImportExport::ExportPolicy::SETTING_KEY, { 'allow_json' => true })
  end

  def post_export(overrides = {})
    body = { module_type: 'leads', format: 'csv', acknowledged: true,
             selected_fields: %w[first_name email] }.merge(overrides)
    post '/api/v1/export_jobs', params: body, headers: headers
  end

  describe 'format gating' do
    it 'refuses JSON while the tenant flag is off' do
      post_export(format: 'json')

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)['allowed_formats']).to contain_exactly('csv', 'xlsx')
      expect(ExportJob.count).to eq(0)
    end

    it 'accepts JSON once the tenant flag is on' do
      allow_json!
      post_export(format: 'json')

      expect(response).to have_http_status(:created)
      expect(ExportJob.last.format).to eq('json')
    end

    it 'always accepts CSV' do
      post_export(format: 'csv')
      expect(response).to have_http_status(:created)
    end
  end

  describe 'acknowledgement' do
    it 'refuses an export that was never acknowledged' do
      post_export(acknowledged: false)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['acknowledgement_text']).to be_present
      expect(ExportJob.count).to eq(0)
    end

    it 'stores the assent verbatim on the job' do
      post_export

      job = ExportJob.last
      expect(job.acknowledged_at).to be_present
      expect(job.acknowledgement_text).to eq(ImportExport::ExportPolicy::ACKNOWLEDGEMENT_TEXT)
      expect(job.requested_ip).to be_present
      expect(job.watermark_token).to match(/\AEXP-[0-9A-F]{16}\z/)
    end
  end

  describe 'rate limiting' do
    it 'refuses past the tenant limit' do
      Setting.set(ImportExport::ExportPolicy::SETTING_SCOPE, company.id,
                  ImportExport::ExportPolicy::SETTING_KEY, { 'daily_export_limit' => 1 })

      post_export
      expect(response).to have_http_status(:created)

      post_export
      expect(response).to have_http_status(:too_many_requests)
      expect(ExportJob.count).to eq(1)
    end
  end

  describe 'field curation' do
    it 'drops an excluded field the request named directly' do
      post_export(selected_fields: %w[first_name health_score champion_status email])

      expect(ExportJob.last.selected_fields).to eq(%w[first_name email])
    end
  end

  describe 'audit trail' do
    it 'writes an activity log entry for the request' do
      expect { post_export }.to change {
        ActivityLog.where(company_id: company.id, action: 'export_requested').count
      }.by(1)

      log = ActivityLog.where(action: 'export_requested').last
      expect(log.user_id).to eq(user.id)
      expect(log.module_name).to eq('data_import_export')
      expect(log.metadata['watermark_token']).to eq(ExportJob.last.watermark_token)
    end

    it 'writes an activity log entry for the download' do
      post_export
      job = ExportJob.last
      job.update!(status: 'completed', file_url: '/nonexistent/path.csv', row_count: 5)

      expect {
        get "/api/v1/export_jobs/#{job.id}/download", headers: headers
      }.to change {
        ActivityLog.where(company_id: company.id, action: 'export_downloaded').count
      }.by(1)

      expect(job.reload.download_count).to eq(1)
      expect(job.downloaded_at).to be_present
    end
  end

  describe 'GET /policy' do
    it 'reports what this tenant may do' do
      get '/api/v1/export_jobs/policy', headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['allowed_formats']).to contain_exactly('csv', 'xlsx')
      expect(body['acknowledgement_text']).to be_present
      expect(body['remaining_today']).to eq(ImportExport::ExportPolicy::DEFAULTS['daily_export_limit'])
    end
  end
end
