# frozen_string_literal: true

require 'rails_helper'

# The endpoint a push tap resolves through. It exists so the client knows which
# location to switch to before navigating, and so a stale target degrades to the
# notification center rather than a 404.
RSpec.describe 'GET /api/v1/notifications/:id/target', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Tap', last_name: 'User',
                 password: 'Pass1234!', company_id: company.id, role: 'user')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  def make_notification(recipient: user, **attrs)
    Notification.create!({
      company: company, recipient: recipient,
      notification_type: 'lead_assigned', category: 'crm',
      title: 'A lead was assigned', message: 'msg', priority: 'normal'
    }.merge(attrs))
  end

  it 'refuses without auth' do
    note = make_notification
    get "/api/v1/notifications/#{note.id}/target"
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns the path and marks the notification read' do
    note = make_notification(action_url: '/crm/leads/42?tab=activities')

    get "/api/v1/notifications/#{note.id}/target", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['ok']).to be true
    expect(body['path']).to eq('/crm/leads/42?tab=activities')
    expect(note.reload.read).to be true
  end

  it 'reports a fallback rather than a path when there is nothing to open' do
    note = make_notification(action_url: nil, notification_type: 'system_alert', category: 'system')

    get "/api/v1/notifications/#{note.id}/target", headers: headers

    body = JSON.parse(response.body)
    expect(body['ok']).to be false
    expect(body['path']).to be_nil
    expect(body['fallback_path']).to eq('/notifications')
  end

  it 'carries the location so the client can switch to it before navigating' do
    note = make_notification(action_url: '/crm/leads/42', location_id: 987)

    get "/api/v1/notifications/#{note.id}/target", headers: headers

    expect(JSON.parse(response.body)['location_id']).to eq(987)
  end

  it 'derives the location from the record when the notification has none' do
    location = Location.create!(company_id: company.id, name: "Lot-#{SecureRandom.hex(2)}")
    lead = Lead.create!(company_id: company.id, first_name: 'L', last_name: 'Ead',
                        email: "l-#{SecureRandom.hex(3)}@example.com", location_id: location.id)
    note = make_notification(notifiable: lead, location_id: nil)

    get "/api/v1/notifications/#{note.id}/target", headers: headers

    body = JSON.parse(response.body)
    expect(body['location_id']).to eq(location.id)
    expect(body['path']).to eq("/crm/leads/#{lead.id}?tab=activities")
  end

  it 'will not resolve someone else\'s notification' do
    other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'U',
                         password: 'Pass1234!', company_id: company.id, role: 'user')
    note = make_notification(recipient: other)

    get "/api/v1/notifications/#{note.id}/target", headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
