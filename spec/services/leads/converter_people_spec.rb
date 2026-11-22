# frozen_string_literal: true

require 'rails_helper'

# Converting a lead (Tom, 2026-11-22): the account takes the email, phone and
# address the convert dialog shows (from the lead, editable), and the deal's
# people card starts with the lead as Buyer and its second person as Co-Buyer.
RSpec.describe Leads::Converter, 'people and account details' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:lead) do
    company.leads.create!(first_name: 'Keianna', last_name: 'Walker', email: 'k@example.com', phone: '2605550100',
                          street: '1 Main', city: 'Elkhart', state: 'IN', zip: '46514',
                          co_applicant_first_name: 'Dre', co_applicant_last_name: 'Walker')
  end

  def convert(**opts) = described_class.new(lead, company: company, user: user).call(deal_params: { name: 'Walker' }, **opts)

  it 'gives the account the lead details when the dialog sends none' do
    account = convert.account
    expect([account.email, account.billing_street, account.billing_city]).to eq(['k@example.com', '1 Main', 'Elkhart'])
  end

  it 'uses what the dialog sent, blank included' do
    account = convert(account_details: { email: 'house@example.com', street: '9 Elm', phone: '' }).account
    expect(account.email).to eq('house@example.com')
    expect(account.billing_street).to eq('9 Elm')
    expect(account.phone).to be_nil
    expect(account.billing_city).to eq('Elkhart') # not sent: from the lead
  end

  it 'starts the deal people card with Buyer and Co-Buyer' do
    result = convert
    people = result.deal.entity_buyers.active.ordered.map { |e| [e.contact.first_name, e.role] }
    expect(people).to eq([%w[Keianna buyer], %w[Dre co_buyer]])
  end
end
