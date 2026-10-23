# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Release queue', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:platform) do
    User.create!(email: "rq-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', company: company,
                 first_name: 'R', last_name: 'Q', status: 'active', role: 'platform_admin')
  end

  def auth(u)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: company.id)}" }
  end

  def build_at(at)
    Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: at, modules_hash: 'x')
  end

  it 'keeps listing an old build while it still has items waiting for review' do
    waiting = build_at(30.days.ago)
    done    = build_at(29.days.ago)
    Knowledge::ChangeQueueItem.create!(snapshot: waiting, change_type: 'added', entity_type: 'atlas_entry', entity_key: 'page:/tasks')
    Knowledge::ChangeQueueItem.create!(snapshot: done, change_type: 'added', entity_type: 'atlas_entry', entity_key: 'page:/tags', status: 'rejected')
    20.times { |i| build_at(i.days.ago) }

    get '/api/admin/guide/releases', headers: auth(platform)
    ids = JSON.parse(response.body)['releases'].map { |r| r['id'] }

    expect(ids.size).to eq(21)
    expect(ids.last).to eq(waiting.id)
    expect(ids).not_to include(done.id)
  end
end
