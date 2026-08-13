# frozen_string_literal: true

require 'rails_helper'

# A repeat inquiry notifies the lead owner ONCE.
#
# It used to notify twice: LeadActivity's after_create :schedule_reminders
# already sends immediately when reminder_time is now, and notify_repeat_inquiry
# called ActivityReminderService a second time on the record it had just
# created. Every deduped Facebook/Zapier lead produced two bell notifications
# and, for owners with the SMS channel on, two Twilio messages.
#
# The existing webhook specs missed it because their leads have no owner, so
# notify_repeat_inquiry returned before creating any activity at all.
RSpec.describe 'Api::Partner::V1 Leads repeat-inquiry notification', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }

  let(:owner) do
    User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'W',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end

  let(:creator) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  let(:key) do
    ApiKey.new(company_id: company.id, name: 'Facebook Leads — Evangeline Home Center',
               key: "ri_live_#{SecureRandom.hex(24)}",
               permissions: { 'leads' => %w[read create] }, status: 'active',
               created_by_user_id: creator.id,
               webhook_config: { default_location_id: location.id, dedupe_enabled: true })
          .tap { |k| k.save!(validate: false) }
  end

  let!(:existing_lead) do
    Lead.create!(company_id: company.id, location_id: location.id, owner_id: owner.id,
                 first_name: 'Latasha', last_name: 'Smith',
                 email: 'latasha@example.com', status: 'engaged')
  end

  def headers_for(k)
    { 'Authorization' => "Bearer #{k.key}", 'Content-Type' => 'application/json' }
  end

  def post_repeat_inquiry
    post '/api/partner/v1/leads',
         params: { full_name: 'Latasha Smith', email: 'latasha@example.com',
                   raw: { '0' => 'Yes', '1' => '30-60 days' } }.to_json,
         headers: headers_for(key)
  end

  it 'sends the owner exactly one notification' do
    expect { post_repeat_inquiry }
      .to change { Notification.where(recipient_id: owner.id).count }.by(1)

    expect(response).to have_http_status(:accepted)
  end

  it 'creates exactly one reminder activity' do
    post_repeat_inquiry

    activities = LeadActivity.where(lead_id: existing_lead.id, activity_type: 'reminder')
    expect(activities.count).to eq(1)
    expect(activities.first.subject).to eq('Repeat Inquiry on Existing Lead: Latasha Smith')
    expect(activities.first.reminder_sent).to be(true)
  end

  it 'still deduplicates rather than creating a second lead' do
    expect { post_repeat_inquiry }.not_to change { Lead.where(company_id: company.id).count }

    body = JSON.parse(response.body)
    expect(body['data']).to be_nil
    expect(body.dig('deduped_to', 'id')).to eq(existing_lead.id)
  end

  # Dedupe matches on email/phone, so a shared household phone folds one
  # person's inquiry into another person's lead. Naming only the matched record
  # made the person who actually filled out the form invisible — the dealer
  # sees "Bob Smith" and no trace of the name they're searching for.
  context 'when the inquiry is from a different person than the matched record' do
    let!(:shared_phone_lead) do
      Lead.create!(company_id: company.id, location_id: location.id, owner_id: owner.id,
                   first_name: 'Bob', last_name: 'Smith',
                   phone: '(303) 555-1212', status: 'engaged')
    end

    it 'names the inquirer and the record it matched' do
      post '/api/partner/v1/leads',
           params: { full_name: 'Tia May', phone: '3035551212' }.to_json,
           headers: headers_for(key)

      expect(response).to have_http_status(:accepted)
      activity = LeadActivity.find_by(lead_id: shared_phone_lead.id, activity_type: 'reminder')
      expect(activity.subject).to eq(
        'Repeat Inquiry on Existing Lead: Tia May (matched to existing record: Bob Smith)'
      )
    end
  end
end
