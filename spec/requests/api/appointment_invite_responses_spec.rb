# frozen_string_literal: true

require 'rails_helper'

# An appointment's card shows how the customer (and the rep) answered its
# calendar invite, so the activity lists carry the answers.
RSpec.describe 'Appointment invite responses on activity lists', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "appt-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Rita', last_name: 'Rep')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:lead) { create(:lead, company: company, first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:answers) do
    { 'responses' => { 'pat@example.com' => { 'status' => 'declined', 'at' => 1.minute.ago.iso8601, 'comment' => 'Out of town' } } }
  end

  before { allow(AppointmentInviteJob).to receive(:perform_later) }

  def appointment_attrs
    { user: user, assigned_to: user, activity_type: 'meeting', subject: 'Walk the Bay Port', status: 'pending',
      priority: 'medium', start_time: 2.days.from_now, end_time: 2.days.from_now + 1.hour }
  end

  it 'lists them on a lead appointment' do
    appt = LeadActivity.create!(lead: lead, **appointment_attrs)
    appt.update_columns(customer_notices: appt.customer_notices.to_h.merge(answers))

    get "/api/crm/leads/#{lead.id}/lead_activities", headers: headers
    expect(response).to have_http_status(:ok)
    rows = JSON.parse(response.body)
    rows = rows['activities'] || rows['data'] || rows if rows.is_a?(Hash)
    row = Array(rows).find { |r| r['id'] == appt.id }
    expect(row['inviteResponses']).to eq([{ 'email' => 'pat@example.com', 'status' => 'declined', 'at' => answers.dig('responses', 'pat@example.com', 'at'),
                                            'comment' => 'Out of town', 'rep' => false }])
  end

  it 'lists them on a deal appointment' do
    contact = Contact.create!(company_id: company.id, first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com')
    deal = Deal.create!(company: company, name: 'Pat Smith home', contact: contact)
    appt = DealActivity.create!(deal: deal, **appointment_attrs)
    appt.update_columns(customer_notices: appt.customer_notices.to_h.merge(answers))

    get "/api/crm/deals/#{deal.id}/deal_activities", headers: headers
    expect(response).to have_http_status(:ok)
    rows = JSON.parse(response.body)
    rows = rows['activities'] || rows['data'] || rows if rows.is_a?(Hash)
    row = Array(rows).find { |r| r['id'] == appt.id }
    expect(row['inviteResponses'].first).to include('status' => 'declined', 'comment' => 'Out of town')
  end
end
