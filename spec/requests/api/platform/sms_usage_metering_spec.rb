# frozen_string_literal: true

require 'rails_helper'

# A text typed on a lead goes out through Api::Platform::CommunicationsController#sms.
# That path recorded no SmsUsageLog at all, so rep-initiated SMS was invisible to
# the usage dashboard and never counted toward the tenant's sms_monthly_limit:
# a dealer working leads by text could not reach their own cap. Campaign and
# service sends were always metered, which is why the gap went unnoticed.
RSpec.describe 'Api::Platform outbound SMS metering', type: :request do
  let(:company) do
    Company.create!(name: "Tenant #{SecureRandom.hex(4)}", industry: 'manufactured_housing',
                    sms_monthly_limit: 100)
  end

  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }
  end

  before do
    Setting.set('Company', company.id, 'communications', {
      'sms' => {
        'provider'         => 'twilio',
        'isEnabled'        => true,
        'fromNumber'       => '+17204632132',
        'twilioAccountSid' => 'ACtest',
        'twilioAuthToken'  => 'token'
      }
    })

    allow_any_instance_of(Api::Platform::CommunicationsController)
      .to receive(:send_sms_via_provider)
      .and_return({ success: true, message_sid: "SM#{SecureRandom.hex(8)}", status: 'queued' })
  end

  it 'meters a text sent on a lead and ties it to the communication' do
    lead = Lead.create!(company_id: company.id, first_name: 'Reese', last_name: 'Test',
                        phone: '3035794057')

    expect {
      post '/api/platform/communications/sms',
           params: { entity_type: 'Lead', entity_id: lead.id, to: '+13035794057',
                     message: 'Hi Tom, this is a test.' },
           headers: headers
    }.to change { SmsUsageLog.for_company(company.id).count }.by(1)

    expect(response).to have_http_status(:created)

    usage = SmsUsageLog.for_company(company.id).last
    expect(usage.direction).to eq('outbound')
    expect(usage.source).to eq('manual')
    expect(usage.billing_period).to eq(SmsUsageLog.current_billing_period)
    expect(usage.communication_id).to eq(JSON.parse(response.body)['id'])
  end

  it 'meters a test send that has no entity to file it against' do
    expect {
      post '/api/platform/communications/sms',
           params: { to: '+13035709810', message: 'This is a test SMS.' },
           headers: headers
    }.to change { SmsUsageLog.for_company(company.id).count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(SmsUsageLog.for_company(company.id).last.communication_id).to be_nil
  end

  it 'counts toward the threshold the tenant was given' do
    50.times { SmsUsageLog.log!(company: company, direction: 'outbound', source: 'manual') }

    post '/api/platform/communications/sms',
         params: { to: '+13035709810', message: 'One more.' },
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(SmsUsageLog.current_period_count(company)).to eq(51)
  end

  it 'still delivers a manual send once the tenant is over its cap' do
    company.update!(sms_monthly_limit: 2)
    2.times { SmsUsageLog.log!(company: company, direction: 'outbound', source: 'manual') }

    post '/api/platform/communications/sms',
         params: { to: '+13035709810', message: 'Over cap but still going.' },
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['success']).to be(true)
    expect(SmsUsageLog.current_period_count(company)).to eq(3)
  end

  it 'does not fail the send when metering blows up' do
    allow(SmsUsageLog).to receive(:log!).and_raise(ActiveRecord::StatementInvalid, 'boom')

    post '/api/platform/communications/sms',
         params: { to: '+13035709810', message: 'Message is already gone.' },
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['success']).to be(true)
  end
end
