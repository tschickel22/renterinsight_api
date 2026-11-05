# frozen_string_literal: true

require 'rails_helper'

# The phone conversation screen asks this before anyone types: has this person
# opted out, and will an answer to a text come back to us.
RSpec.describe 'Api::Platform communication channels', type: :request do
  let(:company) { Company.create!(name: "Chan #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:other_company) { Company.create!(name: "Other #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:contact) { Contact.create!(company: company, first_name: 'Pat', last_name: 'Smith', email: "pat-#{SecureRandom.hex(3)}@example.com") }

  def channels_for(type, id)
    get "/api/platform/communications/#{type}/#{id}/channels", headers: headers
    JSON.parse(response.body)
  end

  it 'reports nothing opted out for someone who has said nothing' do
    body = channels_for('Contact', contact.id)

    expect(response).to have_http_status(:ok)
    expect(body.dig('sms', 'optedOut')).to be(false)
    expect(body.dig('email', 'optedOut')).to be(false)
  end

  it "reads a contact's own opt-out columns" do
    contact.update!(opt_out_sms: true, opt_out_sms_at: Time.utc(2026, 10, 12))

    body = channels_for('Contact', contact.id)

    expect(body.dig('sms', 'optedOut')).to be(true)
    expect(body.dig('sms', 'optedOutAt')).to start_with('2026-10-12')
    expect(body.dig('email', 'optedOut')).to be(false)
  end

  it 'reads a STOP recorded as a preference, the only opt-out a lead can have' do
    lead = Lead.new(company: company, first_name: 'Dana', last_name: 'Whitfield', email: "dana-#{SecureRandom.hex(3)}@example.com")
    lead.save!(validate: false)
    CommunicationPreference.find_or_create_for(recipient: lead, channel: 'sms').opt_out!('SMS STOP keyword received')

    body = channels_for('Lead', lead.id)

    expect(body.dig('sms', 'optedOut')).to be(true)
    expect(body.dig('sms', 'optedOutAt')).to be_present
    expect(body.dig('email', 'optedOut')).to be(false)
  end

  it 'says replies reach the company only when it has its own active number' do
    expect(channels_for('Contact', contact.id).dig('sms', 'repliesReach')).to be(false)

    TwilioAccount.create!(company: company, phone_number: '+13525588888', phone_number_sid: 'PNown', status: 'active',
                          sub_account_sid: "AC#{'e8' * 16}", auth_token: 'token')

    # A number the company is not set to send from still leaves replies with nowhere to land.
    expect(channels_for('Contact', contact.id).dig('sms', 'repliesReach')).to be(false)

    company.update!(sms_provisioning_mode: 'dedicated')
    expect(channels_for('Contact', contact.id).dig('sms', 'repliesReach')).to be(true)
  end

  it "does not answer for another company's record" do
    outsider = Contact.create!(company: other_company, first_name: 'No', last_name: 'Access', email: "no-#{SecureRandom.hex(3)}@example.com")

    channels_for('Contact', outsider.id)

    expect(response).to have_http_status(:not_found)
  end
end
