# frozen_string_literal: true

require 'rails_helper'

# Campaign 42: with "exclude recipients active in other campaigns" on, the
# members list counted the campaign's own enrollments as "other", so once it
# started every recipient it was sending to vanished and the list showed 33.
RSpec.describe 'Campaign audience members', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'saas') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  def campaign
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "C #{SecureRandom.hex(2)}",
                         campaign_type: 'blast', status: 'running', audience_mode: 'dynamic',
                         from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    c.create_campaign_audience!(source_type: 'Lead', filter_tree: { 'type' => 'and', 'children' => [] },
                                exclude_active_campaign_enrollees: true)
    c
  end

  def lead
    Lead.create!(company: company, first_name: 'L', last_name: SecureRandom.hex(2), email: "l-#{SecureRandom.hex(4)}@example.com")
  end

  def enroll(c, l, status)
    CampaignEnrollment.create!(company_id: company.id, campaign_id: c.id, recipient_type: 'Lead', recipient_id: l.id,
                               email_address_snapshot: l.email, status: status)
  end

  it "keeps the campaign's own recipients, drops ones active elsewhere, and explains the count" do
    mine = campaign
    other = campaign
    receiving = lead
    bounced = lead
    busy_elsewhere = lead
    fresh = lead
    enroll(mine, receiving, 'active')
    enroll(mine, bounced, 'bounced')
    enroll(other, busy_elsewhere, 'active')

    get "/api/v1/campaigns/#{mine.id}/audience/members", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    ids = body['items'].map { |i| i['id'] }
    expect(ids).to include(receiving.id, bounced.id, fresh.id)
    expect(ids).not_to include(busy_elsewhere.id)
    expect(body['meta']['breakdown']).to eq('this_campaign' => { 'active' => 1, 'bounced' => 1 }, 'not_enrolled' => 1)

    bounced_row = body['items'].find { |i| i['id'] == bounced.id }
    expect(bounced_row['enrollments']).to include(hash_including('this_campaign' => true, 'status' => 'bounced'))
  end
end
