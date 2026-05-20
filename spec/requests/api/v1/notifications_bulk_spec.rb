# frozen_string_literal: true

require 'rails_helper'

# Coverage for the bulk Notification endpoints used by the FE
# 'Select all pages' feature in NotificationCenter.
RSpec.describe 'Api::V1::Notifications bulk endpoints', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'Bulk', last_name: 'User',
      password: 'Pass1234!', company_id: company.id,
      role: 'user'
    )
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  def make_notification(recipient: user, co: company, category: 'crm', notification_type: 'lead_assigned', read: false)
    Notification.create!(
      company:           co,
      recipient:         recipient,
      notification_type: notification_type,
      category:          category,
      title:             "T-#{SecureRandom.hex(2)}",
      message:           'msg',
      priority:          'normal',
      read:              read
    )
  end

  describe 'DELETE /api/v1/notifications/bulk_destroy' do
    it 'returns 401 without auth' do
      delete '/api/v1/notifications/bulk_destroy'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'deletes only the supplied ids and ignores the rest' do
      keep   = make_notification
      kill_a = make_notification
      kill_b = make_notification

      delete '/api/v1/notifications/bulk_destroy',
             params: { ids: [kill_a.id, kill_b.id] }.to_json,
             headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['deleted']).to eq(2)
      expect(Notification.where(id: [kill_a.id, kill_b.id])).to be_empty
      expect(Notification.exists?(keep.id)).to be(true)
    end

    it 'with all: true and filters: { unread_only: true } only deletes unread rows' do
      unread_a = make_notification(read: false)
      unread_b = make_notification(read: false)
      already_read = make_notification(read: true)

      delete '/api/v1/notifications/bulk_destroy',
             params: { all: true, filters: { unread_only: true } }.to_json,
             headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['deleted']).to eq(2)
      expect(Notification.where(id: [unread_a.id, unread_b.id])).to be_empty
      expect(Notification.exists?(already_read.id)).to be(true)
    end

    it "never touches another user's notifications, even with all: true" do
      mine = make_notification
      other_user = User.create!(
        email: "other-#{SecureRandom.hex(3)}@example.com",
        first_name: 'O', last_name: 'U',
        password: 'Pass1234!', company_id: company.id, role: 'user'
      )
      theirs = make_notification(recipient: other_user)

      delete '/api/v1/notifications/bulk_destroy',
             params: { all: true }.to_json,
             headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(Notification.exists?(mine.id)).to be(false)
      expect(Notification.exists?(theirs.id)).to be(true)
    end

    it 'rejects an empty ids array when all is not set' do
      delete '/api/v1/notifications/bulk_destroy',
             params: { ids: [] }.to_json,
             headers: auth_headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)['error']).to eq('No ids')
    end
  end

  describe 'POST /api/v1/notifications/bulk_mark_read' do
    it 'returns 401 without auth' do
      post '/api/v1/notifications/bulk_mark_read'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'flips only the supplied unread ids to read' do
      n1 = make_notification(read: false)
      n2 = make_notification(read: false)
      n3 = make_notification(read: false) # not in ids → stays unread

      post '/api/v1/notifications/bulk_mark_read',
           params: { ids: [n1.id, n2.id] }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['marked']).to eq(2)
      expect(n1.reload.read).to be(true)
      expect(n2.reload.read).to be(true)
      expect(n3.reload.read).to be(false)
      expect(n1.read_at).to be_present
    end

    it 'with all: true and filters: { category } only touches that category and ignores already-read rows' do
      svc_unread       = make_notification(category: 'service', read: false)
      svc_already_read = make_notification(category: 'service', read: true)
      crm_unread       = make_notification(category: 'crm',     read: false)

      post '/api/v1/notifications/bulk_mark_read',
           params: { all: true, filters: { category: 'service' } }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      # Only the 1 unread service row should be flipped; already-read svc is ignored
      # because base_scope.unread filters it out, and the crm row is the wrong category.
      expect(JSON.parse(response.body)['marked']).to eq(1)
      expect(svc_unread.reload.read).to be(true)
      expect(svc_already_read.reload.read).to be(true)
      expect(crm_unread.reload.read).to be(false)
    end
  end
end
