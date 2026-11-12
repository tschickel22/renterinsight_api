# frozen_string_literal: true

require 'rails_helper'
require_relative '../../../support/private_files_stub'

# E102: photos, videos and files on a project, phase or sub-task, from the
# dealer or the contractor, seen by the buyer when the dealer shares them.
RSpec.describe 'Project photos and files', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Dana', last_name: 'Dealer', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}" } }
  let(:smith) { Contractor.create!(company: company, name: 'Smith Set-Up', email: 'office@smithsetup.example', status: 'active') }
  let(:project) do
    company.projects.create!(name: 'Diaz home', status: 'active', owner: dealer, customer_email: 'diaz@example.com',
                             client_access_token: SecureRandom.hex(12))
  end
  let!(:phase) { project.project_phases.create!(company: company, name: 'Foundation', position: 0, status: 'in_progress') }
  let!(:task) { phase.project_phase_tasks.create!(company: company, name: 'Pour footings', position: 0) }
  let(:base) { "/api/v1/projects/#{project.id}/documents" }

  def body = JSON.parse(response.body)

  def portal_headers(vendor)
    token = JWT.encode({ contractor_ids: [vendor.id], primary_contractor_id: vendor.id, exp: 1.hour.from_now.to_i },
                       Api::Contractor::BaseController.jwt_secret, 'HS256')
    { 'Authorization' => "Bearer #{token}" }
  end

  def file(name, type)
    path = Rails.root.join('tmp', "spec-#{SecureRandom.hex(3)}-#{name}")
    File.binwrite(path, 'x' * 10)
    Rack::Test::UploadedFile.new(path, type, original_filename: name)
  end

  def upload(name, type, **extra)
    post base, headers: headers, params: { file: file(name, type) }.merge(extra)
    expect(response).to have_http_status(:created), response.body
    body
  end

  def buyer_media
    get "/api/v1/public/project-progress/#{project.client_access_token}"
    expect(response).to have_http_status(:ok)
    { project: body['media'] || [], phase: body['phases'].first['media'] || [] }
  end

  before do
    stub_private_files
    allow(PrivateFiles).to receive(:upload) do |f, folder:|
      key = "#{folder}/#{SecureRandom.hex(4)}-#{f.original_filename}"
      { ref: PrivateFiles.ref(key), key: key, size: 10, content_type: f.content_type }
    end
  end

  it 'adds a photo to a sub-task and shares it with the buyer only when the dealer says so' do
    doc = upload('footings.jpg', 'image/jpeg', documentable_type: 'ProjectPhaseTask', documentable_id: task.id)
    expect(doc).to include('category' => 'photo', 'phase_id' => phase.id, 'task_name' => 'Pour footings',
                           'client_visible' => nil, 'shown_to_client' => false, 'shown_to_contractor' => true,
                           'uploaded_by_name' => 'Dana Dealer')
    expect(buyer_media[:phase]).to be_empty

    # Project setting on: every photo shows under its phase, with the task name.
    patch "/api/v1/projects/#{project.id}", headers: headers, params: { project: { share_media_with_client: true } }
    expect(project.reload.share_media_with_client).to be(true)
    media = buyer_media[:phase]
    expect(media.size).to eq(1)
    expect(media.first).to include('kind' => 'photo', 'taskName' => 'Pour footings', 'from' => company.name)
    expect(media.first['url']).to start_with('https://')

    # The phase can say no for itself.
    phase.update!(share_media_with_client: false)
    expect(buyer_media[:phase]).to be_empty

    # And the dealer's tick on one photo wins over the phase.
    patch "#{base}/#{doc['id']}", headers: headers, params: { client_visible: true }
    expect(body['shown_to_client']).to be(true)
    expect(buyer_media[:phase].size).to eq(1)
  end

  it 'keeps PDFs with the dealer until ticked, and nothing shows under a hidden phase' do
    project.update!(share_media_with_client: true)
    pdf = upload('permit.pdf', 'application/pdf', documentable_type: 'ProjectPhase', documentable_id: phase.id)
    expect(pdf).to include('category' => 'other', 'shown_to_client' => false, 'shown_to_contractor' => false)
    expect(buyer_media[:phase]).to be_empty

    patch "#{base}/#{pdf['id']}", headers: headers, params: { client_visible: true }
    expect(buyer_media[:phase].first).to include('kind' => 'file', 'fileName' => 'permit.pdf')

    phase.update!(visible_to_client: false)
    get "/api/v1/public/project-progress/#{project.client_access_token}"
    expect(body['phases']).to be_empty
    expect(body['media']).to be_empty
  end

  it 'refuses a phase or task from another project' do
    other = company.projects.create!(name: 'Other', status: 'active')
    other_task = other.project_phases.create!(company: company, name: 'Set', position: 0)
                      .project_phase_tasks.create!(company: company, name: 'X', position: 0)
    post base, headers: headers, params: { file: file('a.jpg', 'image/jpeg'), documentable_type: 'ProjectPhaseTask',
                                           documentable_id: other_task.id }
    expect(response).to have_http_status(:not_found)
  end

  it 'puts a contractor work log photo on the project and keeps their stored file when the dealer removes it' do
    assignment = task.contractor_assignments.create!(contractor: smith, company: company, status: 'in_progress', assigned_at: Time.current)
    key = "contractor-work-logs/#{company.id}/#{assignment.id}/forms.jpg"
    foreign = "contractor-work-logs/#{create(:company).id}/#{assignment.id}/not-theirs.jpg"

    post "/api/contractor/tasks/#{assignment.id}/work_logs", headers: portal_headers(smith), as: :json,
         params: { note: 'Forms set', attachments: [
           { url: PrivateFiles.ref(key), s3_key: key, filename: 'forms.jpg', content_type: 'image/jpeg', size: 10 },
           { url: PrivateFiles.ref(foreign), s3_key: foreign, filename: 'not-theirs.jpg', content_type: 'image/jpeg' }
         ] }
    expect(response).to have_http_status(:created)

    get base, headers: headers
    docs = body['documents']
    expect(docs.size).to eq(1) # the other company's file is not taken
    expect(docs.first).to include('source' => 'contractor', 'uploaded_by_name' => 'Smith Set-Up', 'task_name' => 'Pour footings')

    project.update!(share_media_with_client: true)
    expect(buyer_media[:phase].first).to include('from' => 'Smith Set-Up')

    expect(PrivateFiles).not_to receive(:delete)
    delete "#{base}/#{docs.first['id']}", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'records completion photos once, however often the contractor resubmits' do
    assignment = task.contractor_assignments.create!(contractor: smith, company: company, status: 'in_progress', assigned_at: Time.current)
    ref = PrivateFiles.ref("contractor-work-logs/#{company.id}/#{assignment.id}/done.png")
    2.times { ProjectMedia.record_contractor_files!(assignment, [ref]) }
    doc = project.project_documents.sole
    expect(doc).to have_attributes(source: 'contractor', content_type: 'image/png', category: 'photo')
  end

  it "shows the contractor the dealer's photos on their task, not the dealer's PDFs" do
    assignment = task.contractor_assignments.create!(contractor: smith, company: company, status: 'in_progress', assigned_at: Time.current)
    upload('site.jpg', 'image/jpeg', documentable_type: 'ProjectPhase', documentable_id: phase.id)
    upload('invoice.pdf', 'application/pdf', documentable_type: 'ProjectPhaseTask', documentable_id: task.id)

    get "/api/contractor/tasks/#{assignment.id}", headers: portal_headers(smith)
    expect(response).to have_http_status(:ok)
    expect(body['project_files'].map { |f| f['file_name'] }).to eq(['site.jpg'])
  end

  it 'emails the buyer about photos they can see' do
    allow(CommunicationService).to receive(:send_email).and_return(double(status: 'sent'))
    doc = upload('poured.jpg', 'image/jpeg', documentable_type: 'ProjectPhase', documentable_id: phase.id)

    post "#{base}/notify_client", headers: headers, params: { document_ids: [doc['id']] }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(CommunicationService).not_to have_received(:send_email)

    patch "#{base}/#{doc['id']}", headers: headers, params: { client_visible: true }
    post "#{base}/notify_client", headers: headers, params: { document_ids: [doc['id']], note: 'Foundation poured today!' }
    expect(response).to have_http_status(:ok)
    expect(body).to include('sent' => true, 'to' => 'diaz@example.com', 'count' => 1)
    expect(CommunicationService).to have_received(:send_email).with(
      hash_including(to: 'diaz@example.com', subject: 'Diaz home: 1 new photo',
                     body: a_string_including('Foundation poured today!', 'Foundation'))
    )
  end
end
