# frozen_string_literal: true

require 'rails_helper'

# A task's days, customer visibility and required setting typed in the template
# editor must reach the projects built from that template.
RSpec.describe 'Project template task settings', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def body = JSON.parse(response.body)

  def tasks_of(project)
    project.project_phases.first.project_phase_tasks.order(:position).index_by(&:name)
  end

  it 'saves each task setting in the task JSON, loads it back, and builds the project from it' do
    post '/api/v1/project-templates', headers: headers, params: {
      project_template: { name: 'Set-up', template_type: 'land_home' },
      phases: [{
        name: 'Set', visible_to_client: true,
        tasks: [
          { name: 'Level home', estimated_days: 3, visible_to_client: true, is_required: true, task_type: 'task' },
          { name: 'Internal check', estimated_days: 1, visible_to_client: false, is_required: false, task_type: 'task' }
        ]
      }]
    }.to_json
    expect(response).to have_http_status(:created)

    get "/api/v1/project-templates/#{body['template']['id']}", headers: headers
    saved = body['template']['project_template_phases'].first['default_tasks'].index_by { |t| t['name'] }
    expect(saved['Level home']).to include('estimated_days' => 3, 'visible_to_client' => true, 'is_required' => true)
    expect(saved['Internal check']).to include('estimated_days' => 1, 'visible_to_client' => false, 'is_required' => false)

    project = ProjectTemplate.find(body['template']['id']).create_project!(company: company, created_by: admin)
    tasks = tasks_of(project)
    expect(tasks['Level home']).to have_attributes(estimated_days: 3, visible_to_client: true, is_required: true)
    expect(tasks['Internal check']).to have_attributes(estimated_days: 1, visible_to_client: false, is_required: false)
  end

  it 'reads a missing setting from the plain task row an older save wrote beside the JSON' do
    template = company.project_templates.create!(name: 'Older save', template_type: 'standard')
    phase = template.project_template_phases.create!(
      name: 'Set', position: 0,
      default_tasks: [{ 'name' => 'Level home', 'position' => 0, 'task_type' => 'task', 'checklist_items' => [] }]
    )
    phase.project_template_phase_tasks.create!(name: 'Level home', position: 0, estimated_days: 4,
                                               visible_to_client: true, is_required: false)

    project = template.create_project!(company: company, created_by: admin)
    expect(tasks_of(project)['Level home']).to have_attributes(estimated_days: 4, visible_to_client: true, is_required: false)
  end

  it 'keeps the old result for task JSON with no plain row (seeded templates)' do
    template = company.project_templates.create!(name: 'Seeded', template_type: 'standard')
    template.project_template_phases.create!(
      name: 'Set', position: 0,
      default_tasks: [{ 'title' => 'Submit loan application', 'task_type' => 'general', 'estimated_hours' => 2 }]
    )

    project = template.create_project!(company: company, created_by: admin)
    expect(tasks_of(project)['Submit loan application'])
      .to have_attributes(estimated_days: nil, visible_to_client: false, is_required: true)
  end

  it 'copies the plain task rows when a template is duplicated' do
    template = company.project_templates.create!(name: 'Original', template_type: 'standard')
    phase = template.project_template_phases.create!(name: 'Set', position: 0)
    phase.project_template_phase_tasks.create!(name: 'Level home', position: 0, estimated_days: 2, visible_to_client: true)

    copy = template.duplicate!
    expect(copy.project_template_phases.first.project_template_phase_tasks.pluck(:name, :estimated_days))
      .to eq([['Level home', 2]])
  end
end
