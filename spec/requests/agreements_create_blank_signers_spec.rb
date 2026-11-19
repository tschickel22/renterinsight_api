# frozen_string_literal: true

require 'rails_helper'

# The builder auto-saves as soon as a signer count is picked, while the signer
# slots are still empty. A create whose signers fail must not leave the
# agreement behind: the builder never learns its id, so the next save made a
# second agreement and the deal kept an empty Draft with no signers.
RSpec.describe 'Creating an agreement with blank signer slots', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ann', last_name: 'Admin',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }

  def create_with(signers)
    post '/api/v1/agreements', headers: headers, as: :json,
                               params: { agreement: { title: 'Purchase Agreement', content_type: 'upload', signers: signers } }
  end

  it 'saves nothing when a signer slot is blank' do
    expect do
      create_with([{ name: 'Jane Buyer', email: 'jane@example.com', role: 'signer', signing_order: 1 },
                   { name: '', email: '', role: 'signer', signing_order: 2 }])
    end.not_to change { company.agreements.count }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'still saves the agreement and its signers when every slot is filled' do
    expect do
      create_with([{ name: 'Jane Buyer', email: 'jane@example.com', role: 'signer', signing_order: 1 }])
    end.to change { company.agreements.count }.by(1)
    expect(response).to have_http_status(:created)
    expect(company.agreements.last.agreement_signers.pluck(:name)).to eq(['Jane Buyer'])
  end
end
