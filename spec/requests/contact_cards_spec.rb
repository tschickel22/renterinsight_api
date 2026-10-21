# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Contact cards', type: :request do
  let(:company) { Company.create!(name: 'Easy Homesource, Inc.', phone: '3525558888') }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Dana', last_name: 'Lee',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active',
                 phone: '3525550101', title: 'Sales; Homes')
  end

  def token_for(user)
    ContactCard.url_for(user).split('/vc/').last
  end

  it "downloads the rep's card, escaped, for a phone to save" do
    get "/vc/#{token_for(rep)}"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('text/vcard')
    expect(response.headers['Content-Disposition']).to include('dana-lee.vcf')
    expect(response.body).to include('FN:Dana Lee', 'ORG:Easy Homesource\, Inc.', 'TITLE:Sales\; Homes',
                                     'TEL;TYPE=CELL,VOICE:3525550101', 'TEL;TYPE=WORK,VOICE:3525558888',
                                     "EMAIL;TYPE=INTERNET,WORK:#{rep.email}")
  end

  it 'refuses a token that was not signed by us' do
    get "/vc/#{Base64.strict_encode64(rep.id.to_s)}--deadbeef"

    expect(response).to have_http_status(:not_found)
  end

  # A rep who leaves takes their card with them.
  it 'stops serving the card once the rep is no longer active' do
    token = token_for(rep)
    rep.update!(status: 'inactive')

    get "/vc/#{token}"

    expect(response).to have_http_status(:not_found)
  end
end
