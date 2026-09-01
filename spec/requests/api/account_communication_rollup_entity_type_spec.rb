# frozen_string_literal: true

require 'rails_helper'

# The account Communication tab rolls up messages for the account's contacts AND
# its converted leads. It used to return every row's id as contact_id with no
# type, so clicking a lead-linked message sent the UI to /contacts/:lead_id.
# That 404s when no contact holds that number and, worse, opens an unrelated
# contact when one does.
RSpec.describe 'Account communication rollup entity type', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "rollup-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ada', last_name: 'Reyes')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  let(:account) { Account.create!(company_id: company.id, name: "Factory Direct #{SecureRandom.hex(3)}") }

  let!(:contact) do
    Contact.create!(company_id: company.id, account_id: account.id,
                    first_name: 'Casey', last_name: 'Contact', email: 'casey@example.com')
  end
  let!(:lead) do
    create(:lead, company: company, first_name: 'Kyle', last_name: 'Dudgeon',
                  email: 'kyle@example.com', converted_account_id: account.id)
  end

  def email_for(entity)
    Communication.create!(company_id: company.id, communicable: entity, channel: 'email',
                          direction: 'outbound', subject: 'API Help', body: 'hello',
                          from_address: 'tom@dealertide.com', to_address: 'kyle@example.com',
                          sent_at: Time.current)
  end

  before do
    email_for(contact)
    email_for(lead)
  end

  it 'says which kind of record each message belongs to' do
    get "/api/v1/accounts/#{account.id}/communications/rollup", headers: headers

    expect(response).to have_http_status(:ok)
    rows = JSON.parse(response.body)['communications']

    by_name = rows.index_by { |r| r['contact_name'] }
    expect(by_name['Casey Contact']['entity_type']).to eq('Contact')
    expect(by_name['Kyle Dudgeon']['entity_type']).to eq('Lead')
  end

  it 'returns the lead id for the lead row, which is why the type is required' do
    get "/api/v1/accounts/#{account.id}/communications/rollup", headers: headers

    row = JSON.parse(response.body)['communications'].find { |r| r['contact_name'] == 'Kyle Dudgeon' }

    expect(row['contact_id']).to eq(lead.id)
    # Nothing stops that id also existing as a contact, which is the dangerous case.
    expect(row['entity_type']).to eq('Lead')
  end
end
