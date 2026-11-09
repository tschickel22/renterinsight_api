# frozen_string_literal: true

require 'rails_helper'

# A rep's personal cell went out on a starter play's email signature and
# contact card. Account Settings now keeps a mobile, an office line with
# extension, and which one customers see.
RSpec.describe 'Number customers see', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}", phone: '813-555-0000') }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Pat', last_name: 'Yang', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep', status: 'active', phone: '813-484-5038')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }

  it 'saves the office line and the choice from Account Settings, and customers then get the office line' do
    expect(rep.customer_facing_phone).to eq('813-484-5038')

    patch '/api/v1/user_settings/profile', headers: headers,
                                           params: { office_phone: '813-555-0100', office_phone_ext: 'x 12', customer_phone: 'office' }.to_json
    expect(response).to have_http_status(:ok)
    rep.reload
    expect(rep).to have_attributes(phone: '813-484-5038', office_phone: '813-555-0100', office_phone_ext: '12', customer_phone: 'office')
    expect(rep.customer_facing_phone).to eq('813-555-0100 ext. 12')

    get '/api/v1/user_settings/profile', headers: headers
    expect(JSON.parse(response.body)).to include('office_phone' => '813-555-0100', 'office_phone_ext' => '12', 'customer_phone' => 'office')
  end

  it 'falls back to the mobile when office is chosen but no office line is saved' do
    rep.update!(customer_phone: 'office')
    expect(rep.customer_facing_phone).to eq('813-484-5038')
  end

  it 'puts the office line on merge fields and the contact card, and leaves the cell off' do
    rep.update!(office_phone: '813-555-0100', office_phone_ext: '12', customer_phone: 'office')
    lead = Lead.create!(company_id: company.id, first_name: 'Teressa', last_name: 'G', owner_id: rep.id)

    expect(Messaging::MergeTagResolver.build_context(recipient: lead, company: company, rep: rep)['rep_phone']).to eq('813-555-0100 ext. 12')

    card = ContactCard.vcard(rep)
    expect(card).to include('TEL;TYPE=WORK,VOICE:813-555-0100\,12')
    expect(card).not_to include('813-484-5038')
  end
end
