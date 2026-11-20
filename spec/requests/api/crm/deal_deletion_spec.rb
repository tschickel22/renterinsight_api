# frozen_string_literal: true

require 'rails_helper'

# A deal can be deleted from its own page. The delete is permanent, so it is
# refused while money or signed paperwork is still attached to the deal.
RSpec.describe 'Deleting a deal', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let!(:deal) { company.deals.create!(name: 'Smith Lot Home', contact_id: buyer.id) }

  it 'deletes a deal with nothing attached, and the check says nothing stops it' do
    get "/api/crm/deals/#{deal.id}/deletion_check", headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['blockers']).to eq([])

    delete "/api/crm/deals/#{deal.id}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(Deal.exists?(deal.id)).to be(false)
  end

  it 'clears rows that would otherwise stop the delete on a foreign key' do
    rep = User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P', password: 'Pass1234!',
                       company_id: company.id, role: 'user')
    now = Time.current
    Commission.insert_all!([{ company_id: company.id, deal_id: deal.id, user_id: rep.id, commission_type: 'sale',
                              amount: 100, status: 'cancelled', created_at: now, updated_at: now }])
    Invoice.insert_all!([{ company_id: company.id, deal_id: deal.id, status: 'draft', invoice_number: "INV-#{SecureRandom.hex(3)}",
                           invoice_date: Date.current, created_at: now, updated_at: now }])
    draft = Invoice.find_by!(deal_id: deal.id)

    delete "/api/crm/deals/#{deal.id}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(Deal.exists?(deal.id)).to be(false)
    expect(Commission.where(deal_id: deal.id)).to be_empty
    expect(draft.reload.is_deleted).to be(true)
  end

  it 'refuses while an agreement is signed or out for signature, and says why' do
    Agreement.insert_all!([{ company_id: company.id, deal_id: deal.id, status: 'completed', title: 'Purchase Agreement',
                             agreement_number: "AG-#{SecureRandom.hex(3)}", created_at: Time.current, updated_at: Time.current }])

    get "/api/crm/deals/#{deal.id}/deletion_check", headers: headers
    expect(JSON.parse(response.body)['blockers']).to eq(['It has 1 agreement signed or out for signature. Void it first.'])

    delete "/api/crm/deals/#{deal.id}", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)['blockers'].first).to include('agreement')
    expect(Deal.exists?(deal.id)).to be(true)
  end

  it 'refuses while a payment is recorded against it' do
    CashReceipt.insert_all!([{ company_id: company.id, deal_id: deal.id, status: 'posted', amount: 500,
                               receipt_date: Date.current, created_at: Time.current, updated_at: Time.current }])

    delete "/api/crm/deals/#{deal.id}", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)['blockers']).to eq(['It has 1 payment recorded. Void it first.'])
  end

  it 'does not delete a deal from another company' do
    other_co = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    theirs = other_co.contacts.create!(first_name: 'Lee', last_name: 'Ray', email: 'lee@example.com')
    other = other_co.deals.create!(name: 'Theirs', contact_id: theirs.id)
    delete "/api/crm/deals/#{other.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(Deal.exists?(other.id)).to be(true)
  end
end
