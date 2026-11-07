# frozen_string_literal: true

require 'rails_helper'

# A client's onboarding list (backlog E97): we build it in Platform Admin,
# their people work it in Getting started, each side hears about the other.
RSpec.describe 'Client onboarding checklist', type: :request do
  let(:platform) { Company.create!(name: "DealerTide #{SecureRandom.hex(3)}") }
  let(:client) { Company.create!(name: "Easy Homesource #{SecureRandom.hex(3)}") }
  let(:other) { Company.create!(name: "Other #{SecureRandom.hex(3)}") }

  def user(co, role)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: role.split('_').first.capitalize, last_name: 'T',
                 password: 'Pass1234!', company_id: co.id, role: role, status: 'active')
  end

  let(:tom) { user(platform, 'platform_admin') }
  let(:client_admin) { user(client, 'company_admin') }
  let(:client_rep) { user(client, 'sales_rep') }
  let(:outsider) { user(other, 'company_admin') }

  def headers_for(u, co = u.company)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: co.id)}", 'Content-Type' => 'application/json' }
  end

  def body = JSON.parse(response.body)
  def bells(u) = Notification.where(recipient: u, notification_type: 'onboarding_update')

  before do
    OnboardingTemplateItem.create!(section: 'Account and users', title: 'List of users and roles', owed_by: 'client', position: 1)
    OnboardingTemplateItem.create!(section: 'Account and users', title: 'Create users', owed_by: 'dealertide', position: 2)
  end

  it 'starts a client from the standard list, and the client sees it in Getting started' do
    post "/api/admin/onboarding/#{client.id}/start", headers: headers_for(tom)
    expect(response).to have_http_status(:ok)
    expect(body['items'].map { |i| i['title'] }).to eq(['List of users and roles', 'Create users'])
    expect(body['followers'].map { |f| f['id'] }).to eq([tom.id])

    get '/api/v1/onboarding', headers: headers_for(client_rep)
    expect(body['items'].size).to eq(2)
    expect(body['progress']).to include('total' => 2, 'client_open' => 1, 'ours_open' => 1)
  end

  it 'tells the client when we add something they owe, and the assignee only when assigned' do
    client_admin
    post "/api/admin/onboarding/#{client.id}/items", headers: headers_for(tom),
                                                    params: { section: 'TrueBuild pricing', title: 'Decor sheets', owed_by: 'client' }.to_json
    expect(bells(client_admin).count).to eq(1)
    expect(bells(client_rep).count).to eq(0)

    item = client.onboarding_items.find_by!(title: 'Decor sheets')
    patch "/api/admin/onboarding/#{client.id}/items/#{item.id}", headers: headers_for(tom), params: { assignee_id: client_rep.id }.to_json
    expect(bells(client_rep).last.message).to include('Assigned to you')

    patch "/api/admin/onboarding/#{client.id}/items/#{item.id}", headers: headers_for(tom), params: { assignee_id: outsider.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'tells us when the client finishes, writes or uploads, and records each for the activity feed' do
    post "/api/admin/onboarding/#{client.id}/start", headers: headers_for(tom)
    item = client.onboarding_items.find_by!(title: 'List of users and roles')

    post "/api/v1/onboarding/items/#{item.id}/note", headers: headers_for(client_rep), params: { body: 'Sending it today' }.to_json
    post "/api/v1/onboarding/items/#{item.id}/files", headers: headers_for(client_rep).except('Content-Type'),
                                                      params: { file: Rack::Test::UploadedFile.new(StringIO.new('name,role'), 'text/csv', original_filename: 'users.csv') }
    expect(body['item']['files'].map { |f| f['name'] }).to eq(['users.csv'])
    post "/api/v1/onboarding/items/#{item.id}/done", headers: headers_for(client_rep)
    expect(body['item']).to include('status' => 'done', 'done_by' => client_rep.full_name)
    expect(body['item']['notes'].map { |n| [n['side'], n['body']] }).to eq([['client', 'Sending it today']])

    expect(bells(tom).pluck(:message)).to include(a_string_including('Sending it today'), a_string_including('uploaded users.csv'), a_string_including('finished'))
    expect(client.onboarding_events.pluck(:kind)).to include('note', 'upload', 'done')
  end

  it 'keeps the lists apart: no other company reaches an item, and only platform admins manage' do
    post "/api/admin/onboarding/#{client.id}/start", headers: headers_for(tom)
    item = client.onboarding_items.first

    post "/api/v1/onboarding/items/#{item.id}/done", headers: headers_for(outsider)
    expect(response).to have_http_status(:not_found)
    post "/api/admin/onboarding/#{client.id}/items", headers: headers_for(client_admin), params: { section: 'X', title: 'Y' }.to_json
    expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
  end

  it 'saves a client item to the standard list and reports typical days to done' do
    post "/api/admin/onboarding/#{client.id}/items", headers: headers_for(tom),
                                                    params: { section: 'TrueBuild pricing', title: 'Surcharge chart', owed_by: 'client' }.to_json
    item = client.onboarding_items.find_by!(title: 'Surcharge chart')
    post "/api/admin/onboarding/#{client.id}/items/#{item.id}/save_to_standard", headers: headers_for(tom)
    expect(item.reload.template_item).to be_present

    item.update_columns(status: 'done', done_at: item.created_at + 4.days)
    get '/api/admin/onboarding_template', headers: headers_for(tom)
    row = body['items'].find { |t| t['title'] == 'Surcharge chart' }
    expect(row).to include('clients' => 1, 'median_days' => 4.0)
  end

  it 'sends one morning summary per person, only when something happened' do
    Setting.set('Platform', 0, 'communications', { 'email' => { 'fromEmail' => 'hello@example.com', 'fromName' => 'DealerTide' } })
    post "/api/admin/onboarding/#{client.id}/start", headers: headers_for(tom)
    client_admin
    item = client.onboarding_items.find_by!(title: 'List of users and roles')
    Onboarding::Checklist.new(client, actor: client_rep, side: 'client').complete!(item)

    expect { Onboarding::DailySummary.call }.to change { ActionMailer::Base.deliveries.size }.by(2)
    to_tom = ActionMailer::Base.deliveries.find { |m| m.to == [tom.email] }
    expect(to_tom.subject).to include('Client onboarding')
    expect(to_tom.text_part.body.to_s).to include('Finished by', 'List of users and roles')

    ActionMailer::Base.deliveries.clear
    expect(Onboarding::DailySummary.call(now: 3.days.from_now)).to eq(0)
  end

  it 'sends the intro by email and text to the people picked, and remembers it was sent' do
    Setting.set('Platform', 0, 'communications', { 'email' => { 'fromEmail' => 'hello@example.com', 'fromName' => 'DealerTide' } })
    client_admin.update!(phone: '3035550100')
    texts = []
    allow(TwilioSmsService).to receive(:send_via_master) { |to:, body:, **| texts << [to, body]; { success: true } }
    post "/api/admin/onboarding/#{client.id}/start", headers: headers_for(tom)
    expect(body['intro']).to be_nil
    expect(body['intro_people']).to include(client_admin.id)
    copied = user(client, 'sales_rep')
    copied.update_columns(role: 'Company Administrator (Copy)')
    expect(Onboarding::Checklist.client_people(client)).to include(copied)
    expect(Onboarding::Checklist.client_people(client)).not_to include(client_rep)

    expect do
      post "/api/admin/onboarding/#{client.id}/intro", headers: headers_for(tom),
                                                       params: { user_ids: [client_admin.id, client_rep.id], note: 'Call me any time' }.to_json
    end.to change { ActionMailer::Base.deliveries.size }.by(2)
    expect(response).to have_http_status(:ok)
    expect(body['sent']).to include('emails' => 2, 'texts' => 1, 'skipped_texts' => [client_rep.full_name])
    expect(texts.first.last).to include('Getting started', 'Your project', '?getting_started=1')
    mail = ActionMailer::Base.deliveries.last
    expect(mail.reply_to).to eq([tom.email])
    expect(mail.text_part.body.to_s).to include('Call me any time', 'Getting started')
    expect(body['intro']).to include('by' => tom.full_name, 'emails' => 2, 'texts' => 1)

    post "/api/admin/onboarding/#{client.id}/intro", headers: headers_for(tom), params: { user_ids: [outsider.id] }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
