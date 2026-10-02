# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Setup and installation projects through the connector: read what the person
# can read in the app, change tasks and checklist steps the way the app does,
# and never email a customer without the person saying yes first.
RSpec.describe 'MCP project tools', :mcp, type: :request do
  before do
    seed_rbac!
    TenantModuleOverride.create!(company_id: company.id, module_key: 'management.projects', is_enabled: true)
  end

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:boulder) { company.locations.create!(name: 'Boulder', timezone: 'America/Denver') }
  let(:grants) { { 'projects' => %w[read create update], 'deals' => %w[read update] } }
  let(:user) { connector_user(company, grants) }
  let(:token) { connect!(user)['access_token'] }
  let!(:admin) { connector_user(company, {}, role: 'company_admin') }

  def project!(attrs = {}, phases: [['Site prep', 'in_progress', nil], ['Delivery', 'not_started', nil]])
    project = company.projects.create!({ name: 'Diaz home', status: 'active', customer_name: 'Ana Diaz',
                                         customer_email: 'ana@example.com', location_id: denver.id,
                                         owner_id: user.id }.merge(attrs))
    phases.each_with_index do |(name, status, due), i|
      project.project_phases.create!(company: company, name: name, position: i, status: status,
                                     estimated_completion_date: due, visible_to_client: true)
    end
    project.update_progress_cache!
    project
  end

  def phase(project, name)
    project.project_phases.find_by!(name: name)
  end

  def step!(phase, attrs = {})
    phase.project_phase_tasks.create!({ company: company, name: 'Pour footers', position: 0, status: 'pending' }.merge(attrs))
  end

  def task!(project, phase, attrs = {})
    ProjectTask.create!({ company: company, project: project, project_phase: phase, title: 'Order skirting',
                          status: 'pending', priority: 'medium' }.merge(attrs))
  end

  def undo(change)
    post "/api/v1/connected-apps/changes/#{change.id}/undo", headers: app_headers(admin)
    response.parsed_body
  end

  describe 'reading' do
    it 'lists active projects with progress, current phase and overdue counts' do
      p = project!
      task!(p, phase(p, 'Site prep'), due_date: 3.days.ago.to_date)
      company.projects.create!(name: 'Done one', status: 'completed', location_id: denver.id)

      result, error = call_tool(token, 'list_projects')
      expect(error).to be_falsey
      expect(result['items'].map { |i| i['id'] }).to eq(["project:#{p.id}"])
      item = result['items'].first
      expect(item).to include('current_phase' => 'Site prep', 'customer' => 'Ana Diaz', 'overdue_items' => 1,
                              'owner' => user.full_name)
    end

    it 'finds projects behind schedule by their own date or a late phase, and not ones without dates' do
      late_phase = project!({ name: 'Late phase' }, phases: [['Set', 'in_progress', 2.days.ago.to_date]])
      late_project = project!({ name: 'Late project', estimated_completion_date: 1.day.ago.to_date })
      done_phase = project!({ name: 'Done phase' }, phases: [['Set', 'completed', 9.days.ago.to_date]])
      project!({ name: 'No dates' })
      step_late = project!({ name: 'Step late' }, phases: [['Set', 'in_progress', 5.days.from_now.to_date]])
      step!(phase(step_late, 'Set'), estimated_completion_date: 1.day.ago.to_date)

      result, = call_tool(token, 'list_projects', behind_schedule: true)
      names = result['items'].map { |i| i['name'] }
      expect(names).to contain_exactly(late_phase.name, late_project.name, step_late.name)
      expect(names).not_to include(done_phase.name)
    end

    it 'gets one project with phases, steps and open tasks, and hides job costs unless the dealer allows cost' do
      p = project!({ budget_amount: 20_000, actual_cost: 22_000 })
      step!(phase(p, 'Site prep'))
      task!(p, phase(p, 'Site prep'), due_date: Date.current + 2, assigned_to_id: user.id)

      result, = call_tool(token, 'get_project', id: "project:#{p.id}")
      expect(result['phases'].map { |ph| ph['name'] }).to eq(['Site prep', 'Delivery'])
      expect(result['phases'].first['steps'].first).to include('title' => 'Pour footers', 'status' => 'pending')
      expect(result['open_tasks'].first).to include('title' => 'Order skirting', 'assigned_to' => user.full_name)
      expect(result).not_to have_key('costs')
      expect(result['costs_hidden']).to include('Settings, Integrations, AI Apps')
      expect(result.to_s).not_to include('22000')

      Setting.set('Company', company.id, 'mcp_settings', { 'show_costs' => true })
      result, = call_tool(token, 'get_project', id: "project:#{p.id}")
      expect(result['costs']).to include('budget' => 20_000.0, 'actual_cost' => 22_000.0, 'over_budget' => true)
      expect(result).not_to have_key('costs_hidden')
    end

    it 'lists steps and tasks across projects, using the phase date when a step has none' do
      p = project!({}, phases: [['Site prep', 'in_progress', 1.day.ago.to_date]])
      step!(phase(p, 'Site prep'))
      task!(p, phase(p, 'Site prep'), due_date: Date.current + 10, assigned_to_id: user.id)

      result, = call_tool(token, 'list_project_tasks', overdue_only: true)
      expect(result['items'].map { |i| i['kind'] }).to eq(['phase_step'])
      expect(result['items'].first).to include('due_source' => 'phase', 'overdue' => true)

      mine, = call_tool(token, 'list_project_tasks', assigned: 'me')
      expect(mine['items'].map { |i| i['title'] }).to eq(['Order skirting'])
    end

    it 'lists a step once when a bare project task copies it, but keeps a copy that has its own date' do
      p = project!
      step!(phase(p, 'Site prep'), name: 'Prepare purchase agreement')
      task!(p, phase(p, 'Site prep'), title: 'Prepare purchase agreement')
      step!(phase(p, 'Site prep'), name: 'Order skirting', position: 1)
      task!(p, phase(p, 'Site prep'), title: 'Order skirting', due_date: Date.current + 3)

      result, = call_tool(token, 'list_project_tasks', project_id: "project:#{p.id}")
      titles = result['items'].map { |i| [i['kind'], i['title']] }
      expect(titles.count { |_, t| t == 'Prepare purchase agreement' }).to eq(1)
      expect(titles).to include(%w[project_task Order\ skirting])
      expect(result['tasks_hidden_as_copies_of_steps']).to eq(1)
    end

    it 'orders by due date with undated work last, then phase order, then position, the same every call' do
      p = project!({}, phases: [['Site prep', 'in_progress', nil], ['Delivery', 'not_started', nil],
                                ['Set', 'not_started', nil]])
      # Created out of order on purpose, so id order would be wrong.
      step!(phase(p, 'Set'), name: 'Level home', position: 0)
      step!(phase(p, 'Delivery'), name: 'Clear path', position: 1)
      step!(phase(p, 'Site prep'), name: 'Pour footers', position: 1)
      step!(phase(p, 'Delivery'), name: 'Book transport', position: 0)
      step!(phase(p, 'Site prep'), name: 'Soil test', position: 0)
      task!(p, phase(p, 'Delivery'), title: 'Order skirting', position: 5)
      task!(p, phase(p, 'Set'), title: 'Dated task', due_date: Date.current + 3)
      step!(phase(p, 'Set'), name: 'Dated step', position: 9, estimated_completion_date: Date.current + 1)

      expected = ['Dated step', 'Dated task', 'Soil test', 'Pour footers', 'Book transport', 'Clear path',
                  'Order skirting', 'Level home']
      2.times do
        result, = call_tool(token, 'list_project_tasks')
        expect(result['items'].map { |i| i['title'] }).to eq(expected)
      end
    end

    it 'keeps to the plan, the role, the company and the person\'s locations' do
      p = project!
      other = Company.create!(name: 'Other', industry: 'manufactured_housing')
      theirs = other.projects.create!(name: 'Theirs', status: 'active')

      _, error, text = call_tool(token, 'get_project', id: "project:#{theirs.id}")
      expect(error).to be(true)
      expect(text).to include('No record')

      boulder_project = project!({ name: 'Boulder job', location_id: boulder.id })
      unlocated = project!({ name: 'No location', location_id: nil })
      local = connector_user(company, grants, location: denver)
      local_token = connect!(local)['access_token']
      result, = call_tool(local_token, 'list_projects')
      names = result['items'].map { |i| i['name'] }
      expect(names).to include(p.name, unlocated.name)
      expect(names).not_to include(boulder_project.name)

      reader = connector_user(company, { 'deals' => %w[read] })
      _, error, text = call_tool(connect!(reader)['access_token'], 'list_projects')
      expect(error).to be(true)
      expect(text).to include('projects')

      TenantModuleOverride.where(company_id: company.id, module_key: 'management.projects').update_all(is_enabled: false)
      Rails.cache.clear
      _, error, text = call_tool(token, 'list_projects')
      expect(error).to be(true)
      expect(text).to include('Project Management is not part')
    end
  end

  describe 'changing work' do
    it 'hides the write tools from a read-only connection' do
      read_only = connect!(user, allow_write: false)['access_token']
      names = mcp_post(read_only, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('list_projects', 'get_project')
      expect(names).not_to include('update_project_task', 'create_project_task')
    end

    it 'completes a project task through the app path and undoes it' do
      p = project!
      t = task!(p, phase(p, 'Site prep'))

      result, error = call_tool(token, 'update_project_task', id: "project_task:#{t.id}", status: 'completed',
                                                               actual_hours: 3)
      expect(error).to be_falsey
      expect(result['updated']).to include('status' => 'completed', 'actual_hours' => 3.0)
      expect(t.reload.completed_at).to eq(Date.current)
      expect(result['notified']).to eq('customer' => false, 'team' => false)

      expect(undo(McpChange.last)).to include('undone' => true)
      expect(t.reload).to have_attributes(status: 'pending', completed_at: nil, actual_hours: nil)
    end

    it 'will not start a blocked task' do
      p = project!
      first = task!(p, phase(p, 'Site prep'), title: 'Permit')
      second = task!(p, phase(p, 'Site prep'), title: 'Dig')
      ProjectTaskDependency.create!(task: second, depends_on: first, dependency_type: 'finish_to_start')

      _, error, text = call_tool(token, 'update_project_task', id: "project_task:#{second.id}", status: 'in_progress')
      expect(error).to be(true)
      expect(text).to include('blocked by: Permit')
    end

    it 'starts a phase without asking when its "notify client on start" switch is off' do
      p = project!
      s = step!(phase(p, 'Delivery'), name: 'Schedule transport')

      result, error, text = call_tool(token, 'update_project_task', id: "phase_step:#{s.id}", status: 'completed')
      expect(error).to be_falsey, text
      expect(result).to include('phase_started' => true)
      expect(result['notified']['customer']).to be(false)
    end

    it 'stops before a step that would email the customer, then goes ahead once the person agrees' do
      p = project!
      delivery = phase(p, 'Delivery')
      delivery.update!(notify_client_on_start: true)
      s = step!(delivery, name: 'Schedule transport')

      _, error, text = call_tool(token, 'update_project_task', id: "phase_step:#{s.id}", status: 'completed')
      expect(error).to be(true)
      expect(text).to include('emails the customer')
      expect(s.reload.status).to eq('pending')

      allow(ProjectNotificationService).to receive(:notify_phase_change)
      result, = call_tool(token, 'update_project_task', id: "phase_step:#{s.id}", status: 'completed',
                                                         customer_notification_ok: true)
      expect(result).to include('phase_started' => true, 'phase_status' => 'in_progress')
      expect(result['notified']['customer']).to be(true)
      expect(s.reload.status).to eq('completed')
      expect(ProjectNotificationService).to have_received(:notify_phase_change).with(delivery, 'not_started', 'in_progress')

      body = undo(McpChange.last)
      expect(body['undone']).to be(true)
      expect(body['message']).to include('cannot be recalled', 'stays in progress')
      expect(s.reload.status).to eq('pending')
    end

    it 'checks off a step in a started phase without asking, and needs deals update like the app' do
      p = project!
      s = step!(phase(p, 'Site prep'))

      result, error = call_tool(token, 'update_project_task', id: "phase_step:#{s.id}", status: 'completed')
      expect(error).to be_falsey
      expect(result['phase_started']).to be(false)

      viewer = connector_user(company, { 'projects' => %w[read update], 'deals' => %w[read] })
      _, error, text = call_tool(connect!(viewer)['access_token'], 'update_project_task',
                                 id: "phase_step:#{s.id}", status: 'pending')
      expect(error).to be(true)
      expect(text).to include('update on deals')
    end

    it 'adds a task to the current phase and removes it on undo while untouched' do
      p = project!
      result, error = call_tool(token, 'create_project_task', project_id: "project:#{p.id}", title: 'Book inspector',
                                                               due_date: (Date.current + 5).iso8601, assigned_to_user_id: user.id)
      expect(error).to be_falsey
      task = ProjectTask.find(result['created']['id'].split(':').last)
      expect(task).to have_attributes(project_phase_id: phase(p, 'Site prep').id, status: 'pending', company_id: company.id)

      expect(undo(McpChange.last)).to include('undone' => true)
      expect(task.reload.is_deleted).to be(true)
    end

    it 'leaves an edited task alone on undo' do
      p = project!
      call_tool(token, 'create_project_task', project_id: "project:#{p.id}", title: 'Book inspector')
      ProjectTask.last.update!(status: 'in_progress')

      body = undo(McpChange.last)
      expect(body['undone']).to be(false)
      expect(ProjectTask.last.is_deleted).to be_falsey
    end
  end
end
