# frozen_string_literal: true

require 'rails_helper'

# E68: the installer dashboard's jobs card, and dealer task lists that leave
# out tasks a linked installer ticks off.
RSpec.describe 'Dashboard jobs summary', type: :request do
  let(:company) { create(:company, name: 'Ridge Installs', industry: 'installer') }
  let(:dealer_co) { create(:company, name: 'Summit Homes') }
  let(:user) do
    User.create!(email: 'boss@ridge.example', first_name: 'A', last_name: 'B', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end

  def h = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }
  def data = JSON.parse(response.body)['data']

  def job(name, status: 'active')
    company.projects.create!(name: name, status: status, owner: user, actual_completion_date: (Date.current if status == 'completed'))
  end

  it 'counts active jobs, phases starting this week, phases behind, and lists what is coming up' do
    today = Date.current
    a = job('Diaz home')
    a.project_phases.create!(company: company, name: 'Set', position: 0, status: 'in_progress',
                             estimated_start_date: today - 5, estimated_completion_date: today - 1)
    a.project_phases.create!(company: company, name: 'Finish', position: 1, status: 'not_started',
                             estimated_start_date: today + 3, estimated_completion_date: today + 6)
    b = job('Lee home')
    b.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started', estimated_start_date: today + 30)
    job('Old home', status: 'completed')

    get '/api/v1/dashboard/metrics/jobs_summary', headers: h
    expect(response).to have_http_status(:ok), response.body
    expect(data).to include('active_jobs' => 2, 'starting_this_week' => 1, 'behind_schedule' => 1,
                            'completed_in_range' => 1, 'waiting_from_dealers' => 0)
    expect(data['coming_up'].map { |r| [r['project_name'], r['phase_name'], r['late']] })
      .to eq([['Diaz home', 'Set', true], ['Diaz home', 'Finish', false]])
  end

  it 'sends the Project Status card the phases its active projects are in, with days per phase' do
    a = job('Diaz home')
    set = a.project_phases.create!(company: company, name: 'Set', position: 0, status: 'in_progress')
    a.project_phases.create!(company: company, name: 'Finish', position: 1, status: 'not_started')
    a.update_columns(current_phase_id: set.id)
    b = job('Lee home')
    done = b.project_phases.create!(company: company, name: 'Set', position: 0, status: 'completed',
                                    started_at: 4.days.ago, completed_at: 2.days.ago)
    fin = b.project_phases.create!(company: company, name: 'Finish', position: 1, status: 'in_progress')
    b.update_columns(current_phase_id: fin.id)

    get '/api/v1/dashboard/metrics/project_velocity', headers: h
    expect(response).to have_http_status(:ok), response.body
    expect(data['total_projects']).to eq(2)
    expect(data['phases']).to eq([
      { 'name' => 'Set', 'phase_key' => 'set', 'count' => 1, 'avg_days_in_phase' => 2.0 },
      { 'name' => 'Finish', 'phase_key' => 'finish', 'count' => 1, 'avg_days_in_phase' => 0.0 }
    ])
    expect(data['drill_down_url']).to eq('/deals/projects')
    expect(done).to be_present
  end

  it 'leaves out dealer tasks under a phase a linked installer runs' do
    project = dealer_co.projects.create!(name: 'Dealer job', status: 'active', owner: User.create!(
      email: 'pat@summit.example', first_name: 'P', last_name: 'Q', password: 'Pass1234!', company_id: dealer_co.id, role: 'company_admin', status: 'active'
    ))
    run = project.project_phases.create!(company: dealer_co, name: 'Set', position: 0, status: 'in_progress')
    own = project.project_phases.create!(company: dealer_co, name: 'Finish', position: 1, status: 'not_started')
    run.project_phase_tasks.create!(company: dealer_co, name: 'Tie down', position: 0)
    own.project_phase_tasks.create!(company: dealer_co, name: 'Skirting', position: 0)
    vendor = Contractor.create!(company: dealer_co, name: 'Ridge', status: 'active')
    link = CompanyLink.create!(dealer_company: dealer_co, installer_company: company, dealer_vendor: vendor,
                               invite_email: user.email, status: 'active')
    pl = ProjectLink.create!(company_link: link, dealer_company: dealer_co, installer_company: company,
                             dealer_project: project, dealer_phase: run, status: 'accepted')
    pl.link_phases.create!(dealer_phase: run)

    tasks = DashboardMetricsService.new(dealer_co, project.owner, { option: 'this_month' }).project_phase_tasks[:tasks]
    expect(tasks.map { |t| t[:name] }).to eq(['Skirting'])
  end
end
