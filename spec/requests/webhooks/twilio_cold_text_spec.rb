# frozen_string_literal: true

require 'rails_helper'

# A text to a dealer's own or provisioned number that answers nothing they
# sent used to be stored on no record, with nobody told. Someone in the CRM
# now gets it on their conversation; anyone else becomes a lead, owned per the
# dealer's Settings, SMS choice, or unassigned with the admins told.
RSpec.describe 'Webhooks::Twilio cold texts', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  def user(role: 'sales_rep', status: 'active')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: SecureRandom.hex(2),
                 password: 'Pass1234!', company_id: company.id, role: role, status: status)
  end
  let!(:admin) { user(role: 'company_admin') }
  let(:number) { '+13525558888' }
  let!(:account) do
    TwilioAccount.create!(company: company, phone_number: number, phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
  end
  let(:from) { '+13525551234' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWILIO_AUTH_TOKEN').and_return(nil)
    allow(ENV).to receive(:[]).with('TWILIO_PHONE_NUMBER').and_return(nil)
  end

  def text(body, sender: from)
    post '/webhooks/twilio/sms/inbound', params: { From: sender, To: number, Body: body, MessageSid: "SM#{SecureRandom.hex(8)}" }
    expect(response).to have_http_status(:ok)
  end

  def notified(type) = Notification.where(notification_type: type.to_s)

  it 'makes a new lead owned by the chosen person, and tells them' do
    rep = user
    UnmatchedTextRouting.new(company).save!(mode: 'user', user_id: rep.id)

    expect { text('Is the 3 bed on Hwy 27 still available?') }.to change { company.leads.count }.by(1)
    lead = company.leads.last
    expect(lead).to have_attributes(owner_id: rep.id, origin: Lead::ORIGIN_SMS, status: 'new', location_id: company.inbound_lead_location.id)
    expect(lead.phone.gsub(/\D/, '').last(10)).to eq('3525551234')
    expect(lead.full_name).to eq('Text from (352) 555-1234')
    expect(lead.source&.name).to eq('Text message')
    comm = Communication.find_by(communicable: lead, direction: 'inbound')
    expect(comm.body).to eq('Is the 3 bed on Hwy 27 still available?')
    expect(notified(:sms_new_lead).pluck(:recipient_id)).to eq([rep.id])

    # A second text is a reply on the same lead now, not another lead.
    expect { text('Also do you take trades?') }.not_to(change { company.leads.count })
  end

  it 'rotates new leads between reps' do
    a = user
    b = user
    UnmatchedTextRouting.new(company).save!(mode: 'round_robin', rotation_user_ids: [a.id, b.id])

    text('Hi', sender: '+13525550001')
    text('Hello', sender: '+13525550002')
    text('Hey', sender: '+13525550003')
    expect(company.leads.order(:id).pluck(:owner_id)).to eq([a.id, b.id, a.id])
  end

  it 'leaves the lead unassigned and tells the admins when nobody is chosen' do
    text('Do you have land home packages?')
    expect(company.leads.last.owner_id).to be_nil
    expect(notified(:sms_new_lead).pluck(:recipient_id)).to eq([admin.id])
  end

  it "puts a text from someone already in the CRM on their record and tells its owner" do
    rep = user
    contact = company.contacts.create!(first_name: 'Pat', last_name: 'Buyer', phone: '(352) 555-1234', owner_id: rep.id)

    expect { text('Calling about my closing') }.not_to(change { company.leads.count })
    expect(Communication.find_by(direction: 'inbound', body: 'Calling about my closing').communicable).to eq(contact)
    expect(notified(:sms_reply_received).pluck(:recipient_id)).to eq([rep.id])
  end

  it 'never makes a lead of an opt-out or help keyword' do
    expect { text('STOP') }.not_to(change { company.leads.count })
    expect { text('HELP') }.not_to(change { company.leads.count })
  end

  describe 'the setting' do
    def headers
      { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
    end

    it 'shows the numbers it covers and saves one person or a rotation' do
      a = user
      b = user
      get '/api/v1/company/unmatched_texts', headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['numbers'].map { |n| n['phone_number'] }).to eq([number])
      expect(body['routing']['mode']).to be_nil

      put '/api/v1/company/unmatched_texts', headers: headers,
                                             params: { mode: 'round_robin', user_id: a.id, rotation_user_ids: [a.id, b.id] }.to_json
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['routing']).to include('mode' => 'round_robin', 'rotation_user_ids' => [a.id, b.id])

      put '/api/v1/company/unmatched_texts', headers: headers, params: { mode: 'user' }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
