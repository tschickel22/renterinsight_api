# frozen_string_literal: true

require 'rails_helper'

# E68: on a handed-off job, the dealer's tasks follow the installer's copies
# of them, and photos and files marked shared cross the link both ways.
RSpec.describe 'Linked job tasks and files', type: :request do
  include ActiveJob::TestHelper

  let(:dealer_co) { create(:company, name: 'Summit Homes') }
  let(:installer_co) { create(:company, name: 'Summit Install') }

  def admin(company, email)
    User.create!(email: email, first_name: 'A', last_name: 'B', password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end

  let(:dealer) { admin(dealer_co, 'pat@summit.example') }
  let(:boss) { admin(installer_co, 'boss@install.example') }
  let(:vendor) { Contractor.create!(company: dealer_co, name: 'Summit Install (vendor)', email: 'boss@install.example', status: 'active') }
  let!(:location) { installer_co.locations.first || installer_co.locations.create!(name: 'Yard', active: true) }
  let!(:linked_addon) { TenantModuleOverride.create!(company: dealer_co, module_key: 'management.linked_companies', is_enabled: true) }
  before { boss }

  let(:project) do
    dealer_co.projects.create!(name: 'Diaz home', status: 'active', owner: dealer, customer_name: 'Maria Diaz',
                               customer_email: 'maria@example.com', customer_phone: '303-555-0100', client_visible: true)
  end
  let!(:set_phase) { project.project_phases.create!(company: dealer_co, name: 'Set', position: 0, status: 'not_started') }
  let!(:finish_phase) { project.project_phases.create!(company: dealer_co, name: 'Finish', position: 1, status: 'not_started') }
  let!(:level_task) { set_phase.project_phase_tasks.create!(company: dealer_co, name: 'Set and level', position: 0) }
  let!(:tie_task) { set_phase.project_phase_tasks.create!(company: dealer_co, name: 'Tie down', position: 1) }

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  def auth(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }
  def body = JSON.parse(response.body)

  def accepted_job!(phase: set_phase)
    post '/api/v1/company_links', headers: h(dealer), params: { vendor_id: vendor.id, email: boss.email }.to_json
    link = CompanyLink.find(body.dig('company_link', 'id'))
    post "/api/v1/company_links/#{link.id}/accept", headers: h(boss), params: { agree: true }.to_json
    post "/api/v1/projects/#{project.id}/project_links", headers: h(dealer),
         params: { company_link_id: link.id, project_phase_id: phase&.id, fee: 4500 }.to_json
    pl = ProjectLink.find(body.dig('project_link', 'id'))
    yield pl if block_given?
    perform_enqueued_jobs { post "/api/v1/project_links/#{pl.id}/accept", headers: h(boss) }
    expect(response).to have_http_status(:ok), response.body
    pl.reload
  end

  describe 'tasks' do
    it "ticks the dealer's task off when the installer does, and finishes the rest with the phase" do
      pl = accepted_job!
      iph = pl.installer_project.project_phases.first
      copies = iph.project_phase_tasks.order(:position)
      expect(copies.map(&:linked_task_id)).to eq([level_task.id, tie_task.id])

      # The installer ticks one off; the dealer's copy follows.
      perform_enqueued_jobs do
        post "/api/v1/projects/#{pl.installer_project_id}/toggle_task", headers: h(boss), params: { phase_id: iph.id, task_id: copies.first.id }.to_json
      end
      expect(response).to have_http_status(:ok), response.body
      expect(level_task.reload.status).to eq('completed')
      expect(set_phase.reload.status).to eq('in_progress')

      # Reopened there, reopened here.
      perform_enqueued_jobs do
        post "/api/v1/projects/#{pl.installer_project_id}/toggle_task", headers: h(boss), params: { phase_id: iph.id, task_id: copies.first.id }.to_json
      end
      expect(level_task.reload.status).to eq('pending')

      # A task the installer adds for its own crew stays with the installer.
      perform_enqueued_jobs do
        post "/api/v1/projects/#{pl.installer_project_id}/phases/#{iph.id}/tasks", headers: h(boss), params: { task: { name: 'Book crane' } }.to_json
      end
      expect(set_phase.project_phase_tasks.pluck(:name)).not_to include('Book crane')

      # The dealer can't tick off a task under a phase the installer runs.
      post "/api/v1/projects/#{project.id}/toggle_task", headers: h(dealer), params: { phase_id: set_phase.id, task_id: tie_task.id }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to include('run by Summit Install')
      expect(tie_task.reload.status).to eq('pending')

      # The installer finishes the phase without ticking every task; the
      # dealer's open tasks finish with it.
      allow(ProjectNotificationService).to receive(:notify_phase_change)
      perform_enqueued_jobs { pl.installer_project.set_phase_status!(iph.reload, 'completed') }
      expect(set_phase.reload.status).to eq('completed')
      expect([level_task, tie_task].map { |t| t.reload.status }).to eq(%w[completed completed])
      expect(pl.company_link.events.where(kind: 'synced').pluck(:summary).join(' ')).to include('Set and level done', 'Set and level reopened')
    end

    it 'leaves tasks on phases that were not handed off alone' do
      finish_phase.project_phase_tasks.create!(company: dealer_co, name: 'Skirting', position: 0)
      accepted_job!
      post "/api/v1/projects/#{project.id}/toggle_task", headers: h(dealer), params: { phase_id: finish_phase.id, task_id: finish_phase.project_phase_tasks.first.id }.to_json
      expect(response).to have_http_status(:ok), response.body
    end
  end

  describe 'photos and files' do
    before do
      n = 0
      allow(PrivateFiles).to receive(:upload) { |_f, folder:| n += 1; { ref: "s3://private/#{folder}/up#{n}.jpg", key: "#{folder}/up#{n}.jpg", size: 3, content_type: 'image/jpeg' } }
      allow(PrivateFiles).to receive(:copy) { |_v, folder:| n += 1; { ref: "s3://private/#{folder}/copy#{n}.jpg", key: "#{folder}/copy#{n}.jpg" } }
      allow(PrivateFiles).to receive(:delete).and_return(true)
      allow(PrivateFiles).to receive(:url) { |v, **| "https://signed.example/#{v}" }
    end

    def upload!(user, project_id, phase_id: nil, category: 'photo', shared: nil)
      params = { file: Rack::Test::UploadedFile.new(StringIO.new('img'), 'image/jpeg', original_filename: 'set.jpg'),
                 title: 'Set day', category: category }
      params.merge!(documentable_type: 'ProjectPhase', documentable_id: phase_id) if phase_id
      params[:shared] = shared unless shared.nil?
      perform_enqueued_jobs { post "/api/v1/projects/#{project_id}/documents", headers: auth(user), params: params }
      expect(response).to have_http_status(:created), response.body
      ProjectDocument.find(body['id'])
    end

    it "shares the installer's photos with the dealer by default, on the matching phase" do
      pl = accepted_job!
      iph = pl.installer_project.project_phases.first

      photo = upload!(boss, pl.installer_project_id, phase_id: iph.id)
      expect(photo.metadata['link_shared']).to be(true)
      copy = ProjectDocument.find(photo.reload.metadata['link_copy_id'])
      expect(copy).to have_attributes(company_id: dealer_co.id, project_id: project.id, documentable_id: set_phase.id, title: 'Set day')
      expect(copy.file_url).to start_with("s3://private/projects/#{dealer_co.id}/#{project.id}/")
      expect(copy.metadata).to include('link_from' => 'Summit Install', 'link_copy_of' => photo.id)

      get "/api/v1/projects/#{project.id}/documents", headers: h(dealer)
      expect(body.dig('meta', 'link_partner')).to eq('name' => 'Summit Install', 'side' => 'dealer')
      expect(body['documents'].map { |d| d['id'] }).to eq([copy.id])

      # The dealer can't pass the installer's photo on.
      patch "/api/v1/projects/#{project.id}/documents/#{copy.id}", headers: h(dealer), params: { shared: true }.to_json
      expect(response).to have_http_status(:unprocessable_entity)

      # A permit stays with the installer unless marked.
      permit = upload!(boss, pl.installer_project_id, phase_id: iph.id, category: 'permit')
      expect(permit.reload.metadata['link_copy_id']).to be_nil

      # Unticking a photo takes the dealer's copy away; ticking it again sends it back.
      perform_enqueued_jobs { patch "/api/v1/projects/#{pl.installer_project_id}/documents/#{photo.id}", headers: h(boss), params: { shared: false }.to_json }
      expect(response).to have_http_status(:ok), response.body
      expect(copy.reload.is_deleted).to be(true)
      perform_enqueued_jobs { patch "/api/v1/projects/#{pl.installer_project_id}/documents/#{photo.id}", headers: h(boss), params: { shared: true }.to_json }
      second = ProjectDocument.find(photo.reload.metadata['link_copy_id'])
      expect(second).not_to eq(copy)
      expect(second.is_deleted).to be(false)

      # Deleting the original deletes the copy.
      perform_enqueued_jobs { delete "/api/v1/projects/#{pl.installer_project_id}/documents/#{photo.id}", headers: h(boss) }
      expect(second.reload.is_deleted).to be(true)
      expect(pl.company_link.events.pluck(:kind)).to include('document_shared', 'document_unshared')
    end

    it 'sends the dealer files marked to share when the installer accepts, and none of the rest' do
      marked = upload!(dealer, project.id, phase_id: set_phase.id, category: 'drawing', shared: true)
      kept = upload!(dealer, project.id, phase_id: set_phase.id, category: 'contract')
      other_phase = upload!(dealer, project.id, phase_id: finish_phase.id, category: 'drawing', shared: true)
      # Nothing crosses before the installer accepts.
      expect(marked.reload.metadata['link_copy_id']).to be_nil

      pl = accepted_job!
      iph = pl.installer_project.project_phases.first
      copy = ProjectDocument.find(marked.reload.metadata['link_copy_id'])
      expect(copy).to have_attributes(company_id: installer_co.id, project_id: pl.installer_project_id, documentable_id: iph.id)
      expect(kept.reload.metadata['link_copy_id']).to be_nil
      # Finish wasn't handed off, so its file stays with the dealer.
      expect(other_phase.reload.metadata['link_copy_id']).to be_nil
      expect(ProjectDocument.where(company_id: installer_co.id).count).to eq(1)

      # Marked later, it crosses straight away.
      perform_enqueued_jobs { patch "/api/v1/projects/#{project.id}/documents/#{kept.id}", headers: h(dealer), params: { shared: true }.to_json }
      expect(kept.reload.metadata['link_copy_id']).to be_present
    end

    it 'shares nothing more once the job is taken back, and keeps what was already shared' do
      pl = accepted_job!
      iph = pl.installer_project.project_phases.first
      photo = upload!(boss, pl.installer_project_id, phase_id: iph.id)
      copy_id = photo.reload.metadata['link_copy_id']

      post "/api/v1/project_links/#{pl.id}/cancel", headers: h(dealer)
      expect(response).to have_http_status(:ok), response.body

      later = upload!(boss, pl.installer_project_id, phase_id: iph.id)
      expect(later.reload.metadata['link_copy_id']).to be_nil
      perform_enqueued_jobs { delete "/api/v1/projects/#{pl.installer_project_id}/documents/#{photo.id}", headers: h(boss) }
      expect(ProjectDocument.find(copy_id).is_deleted).to be(false)
    end
  end
end
