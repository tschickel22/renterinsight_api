# frozen_string_literal: true

require 'rails_helper'

# E108: project phases and tasks on the DealerTide calendar as all-day spans,
# one or several projects at a time, and on a person's private calendar link
# when they choose.
RSpec.describe 'Projects on the calendar', type: :request do
  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let!(:crew_lead) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'Cal', last_name: 'Crew', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:other_company) { Company.create!(name: "Other #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def body = JSON.parse(response.body)

  let!(:garcia) { company.projects.create!(name: 'Garcia set', customer_name: 'Maria Garcia', status: 'active', owner: admin) }
  let!(:lopez) { company.projects.create!(name: 'Lopez set', status: 'active') }
  let!(:cancelled) { company.projects.create!(name: 'Gone', status: 'cancelled', owner: admin) }
  let!(:site) do
    garcia.project_phases.create!(company: company, name: 'Site prep', position: 0,
                                  estimated_start_date: Date.new(2026, 11, 30), estimated_completion_date: Date.new(2026, 12, 2))
  end
  let!(:pad_task) do
    site.project_phase_tasks.create!(company: company, name: 'Grade the pad', position: 0, assigned_to: crew_lead,
                                     estimated_start_date: Date.new(2026, 11, 30))
  end
  let!(:lopez_set) do
    lopez.project_phases.create!(company: company, name: 'Set', position: 0, assigned_to: crew_lead,
                                 estimated_start_date: Date.new(2026, 12, 7), estimated_completion_date: Date.new(2026, 12, 8))
  end
  let!(:undated) { lopez.project_phases.create!(company: company, name: 'Trim', position: 1) }
  let!(:gone_phase) do
    cancelled.project_phases.create!(company: company, name: 'Never', position: 0, estimated_start_date: Date.new(2026, 12, 1))
  end
  let!(:foreign) do
    p = other_company.projects.create!(name: 'Not ours', status: 'active')
    p.project_phases.create!(company: other_company, name: 'Theirs', position: 0, estimated_start_date: Date.new(2026, 12, 1))
  end

  def events(user, **params)
    get '/api/v1/calendar/events', headers: headers_for(user),
                                   params: { start_date: '2026-11-01', end_date: '2026-12-31' }.merge(params)
    expect(response).to have_http_status(:ok), response.body
    body['events'].select { |e| e['type'].to_s.start_with?('project_') }
  end

  it 'shows dated phases and tasks of live projects as all-day spans, colored by project, on All' do
    found = events(admin, view: 'all')
    expect(found.map { |e| e['id'] }).to match_array(%W[project-phase-#{site.id} project-task-#{pad_task.id} project-phase-#{lopez_set.id}])

    phase = found.find { |e| e['id'] == "project-phase-#{site.id}" }
    expect(phase).to include('title' => 'Site prep: Maria Garcia', 'all_day' => true, 'start' => '2026-11-30', 'end' => '2026-12-03',
                             'entity_type' => 'project', 'entity_id' => garcia.id,
                             'color' => ProjectCalendarEvents.color_for(garcia.id))
    task = found.find { |e| e['type'] == 'project_task' }
    expect(task).to include('start' => '2026-11-30', 'end' => '2026-12-01')
  end

  it 'keeps a span that runs past the edge of the window' do
    found = events(admin, view: 'all', start_date: '2026-12-01', end_date: '2026-12-07')
    expect(found.map { |e| e['id'] }).to include("project-phase-#{site.id}", "project-phase-#{lopez_set.id}")
  end

  it 'shows one or several projects when picked' do
    expect(events(admin, view: 'all', project_ids: [lopez.id]).map { |e| e['entity_id'] }.uniq).to eq([lopez.id])
    expect(events(admin, view: 'all', project_ids: [lopez.id, garcia.id]).size).to eq(3)
  end

  it 'on My calendar shows phases of my projects and work assigned to me, not other people\'s tasks' do
    mine = events(admin, view: 'my').map { |e| e['id'] }
    expect(mine).to eq(["project-phase-#{site.id}"])

    crew = events(crew_lead, view: 'my').map { |e| e['id'] }
    expect(crew).to match_array(%W[project-task-#{pad_task.id} project-phase-#{lopez_set.id}])
  end

  it 'leaves projects out when only other types are asked for' do
    expect(events(admin, view: 'all', types: ['meeting'])).to be_empty
    expect(events(admin, view: 'all', types: ['project_phase']).map { |e| e['type'] }.uniq).to eq(['project_phase'])
  end

  describe 'the private calendar link' do
    def feed(user)
      user.update!(calendar_feed_token: SecureRandom.urlsafe_base64(24)) if user.calendar_feed_token.blank?
      travel_to(Time.zone.local(2026, 11, 20, 12)) { get "/calendar/#{user.calendar_feed_token}.ics" }
      response.body
    end

    it 'carries meetings only until the person adds project work' do
      expect(feed(crew_lead)).not_to include('Grade the pad')

      patch '/api/v1/my_availability', headers: headers_for(crew_lead).merge('Content-Type' => 'application/json'),
                                       params: { availability: { calendar_feed_includes: 'meetings_and_projects' } }.to_json
      expect(response).to have_http_status(:ok), response.body
      expect(body['calendar_feed_includes']).to eq('meetings_and_projects')

      ics = feed(crew_lead.reload)
      expect(ics).to include('SUMMARY:Grade the pad: Maria Garcia', 'DTSTART;VALUE=DATE:20261130', 'DTEND;VALUE=DATE:20261201')
      expect(ics).to include('SUMMARY:Set: Lopez set', 'DTEND;VALUE=DATE:20261209')
      expect(ics).not_to include('SUMMARY:Site prep')
    end

    it 'refuses a choice it does not know' do
      patch '/api/v1/my_availability', headers: headers_for(crew_lead).merge('Content-Type' => 'application/json'),
                                       params: { availability: { calendar_feed_includes: 'everything' } }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
