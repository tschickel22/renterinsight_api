# frozen_string_literal: true

require 'rails_helper'

# Exports run on the background worker, which does not share a disk with the
# web server that serves the download, so the file is kept in the private
# bucket and the download reads it from there.
RSpec.describe 'Export files', type: :request do
  let(:company) { Company.create!(name: "Export Store #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "exs-#{SecureRandom.hex(4)}@example.com", first_name: 'E', last_name: 'S',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:bucket) { {} }

  around do |ex|
    old = ENV['PRIVATE_DOCUMENTS_BUCKET']
    ENV['PRIVATE_DOCUMENTS_BUCKET'] = 'private-test'
    ex.run
  ensure
    ENV['PRIVATE_DOCUMENTS_BUCKET'] = old
  end

  before do
    client = instance_double(Aws::S3::Client)
    allow(PrivateFiles).to receive(:client).and_return(client)
    allow(client).to receive(:put_object) { |bucket:, key:, body:, **| self.bucket[key] = body }
    allow(client).to receive(:get_object) { |bucket:, key:| double(body: StringIO.new(self.bucket.fetch(key))) }
  end

  it 'keeps the file in the private bucket, leaves nothing on disk, and downloads it from there' do
    job = ExportJob.create!(company: company, user: user, module_type: 'leads', format: 'csv', status: 'pending',
                            selected_fields: %w[first_name email])
    ImportExport::Exporter.new(job).process!

    job.reload
    expect(job.status).to eq('completed')
    expect(job.file_url).to start_with("s3://private-test/exports/#{company.id}/export_#{job.id}_")
    expect(Dir[Rails.root.join('tmp/exports', "export_#{job.id}_*")]).to be_empty

    get "/api/v1/export_jobs/#{job.id}/download", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers['Content-Disposition']).to include('attachment')
    expect(response.body.lines.first).to include('export_ref')
  end
end
