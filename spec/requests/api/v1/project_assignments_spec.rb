# frozen_string_literal: true

require 'rails_helper'

# E69 endpoints: template defaults are checked against this company, and a
# project or phase owner can be previewed and applied.
RSpec.describe 'Project and template assignments', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:installer) { Contractor.create!(company: company, name: 'Smith Set-Up', status: 'active') }

  before { allow(ContractorAssignmentNotifierJob).to receive_message_chain(:set, :perform_later) }

  def body = JSON.parse(response.body)

  it "refuses a template default naming another company's contractor" do
    theirs = Contractor.create!(company: Company.create!(name: 'Elsewhere'), name: 'Not Ours', status: 'active')

    post '/api/v1/project-templates', headers: headers, params: {
      project_template: { name: 'Set-up' },
      phases: [{ name: 'Set', tasks: [{ name: 'Level', default_vendor_id: theirs.id }] }]
    }.to_json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['errors']).to include('Default contractor must be one of your own contractors')
  end

  it 'saves defaults at every level and builds a project assigned from them' do
    post '/api/v1/project-templates', headers: headers, params: {
      project_template: { name: 'Set-up', template_type: 'land_home', default_vendor_id: installer.id },
      phases: [{ name: 'Set', default_assigned_to_id: admin.id, tasks: [{ name: 'Level' }] }]
    }.to_json

    expect(response).to have_http_status(:created)
    template = body['template']
    expect(template).to include('default_vendor_id' => installer.id, 'template_type' => 'land_home')
    expect(template['project_template_phases'].first['default_assigned_to_id']).to eq(admin.id)

    project = ProjectTemplate.find(template['id']).create_project!(company: company, created_by: admin)
    task = project.project_phases.first.project_phase_tasks.first
    expect(task.contractor_assignments.pluck(:vendor_id)).to eq([installer.id])
    expect(task.assigned_to_id).to eq(admin.id)
  end

  describe 'live project' do
    let(:project) { company.projects.create!(name: 'Diaz home', status: 'active') }
    let!(:phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started') }
    let!(:task) { phase.project_phase_tasks.create!(company: company, name: 'Level home', position: 0) }

    it 'previews a phase owner without saving, then applies it' do
      post "/api/v1/projects/#{project.id}/assign_phase", headers: headers,
           params: { phase_id: phase.id, assigned_vendor_id: installer.id, apply_to_tasks: true, preview: true }.to_json

      expect(body['result']).to include('tasksUpdated' => 1)
      expect(phase.reload.assigned_vendor_id).to be_nil

      post "/api/v1/projects/#{project.id}/assign_phase", headers: headers,
           params: { phase_id: phase.id, assigned_vendor_id: installer.id, apply_to_tasks: true }.to_json

      expect(phase.reload.assigned_vendor_id).to eq(installer.id)
      expect(task.contractor_assignments.pluck(:vendor_id)).to eq([installer.id])

      get "/api/v1/projects/#{project.id}", headers: headers
      expect(body['phases'].first['assigned_vendor']).to include('name' => 'Smith Set-Up')
    end

    it 'refuses an inactive contractor as owner' do
      installer.update!(status: 'inactive')

      post "/api/v1/projects/#{project.id}/assign_project", headers: headers,
           params: { assigned_vendor_id: installer.id, apply_to_phases: true }.to_json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'gives a task added to the phase the phase owner' do
      phase.update!(assigned_vendor_id: installer.id)

      post "/api/v1/projects/#{project.id}/phases/#{phase.id}/tasks", headers: headers,
           params: { task: { name: 'Steps' } }.to_json

      added = phase.project_phase_tasks.find_by(name: 'Steps')
      expect(added.contractor_assignments.pluck(:vendor_id)).to eq([installer.id])
    end

    it 'clears the assignment notice' do
      project.update!(assignment_issues: [{ 'kind' => 'contractor', 'reason' => 'inactive' }])

      delete "/api/v1/projects/#{project.id}/assignment_issues", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(project.reload.assignment_issues).to eq([])
    end
  end
end
