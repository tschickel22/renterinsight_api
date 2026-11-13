# frozen_string_literal: true

require 'rails_helper'

# An account's (or contact's) Deals tab came up empty for anyone who is not a
# company admin when someone else owned the deal: the list defaulted to "My
# Deals". Easy Homesource's "Company Administrator (Copy)" users saw no deals
# on any imported GoHighLevel account. A record's own deals list everyone's
# deals on it; the main Deals list still defaults to "My Deals".
RSpec.describe 'Deals listed on an account or contact page', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:owner) { make_user('owner') }
  let(:viewer) { make_user('viewer') }
  let(:account) { company.accounts.create!(name: 'Alexander Franco') }
  let!(:contact) { company.contacts.create!(first_name: 'Alex', last_name: 'Franco', email: 'af@example.com', account_id: account.id) }
  let!(:deal) do
    company.deals.create!(name: 'Franco home', account_id: account.id, contact_id: contact.id, primary_salesperson_id: owner.id)
  end

  def make_user(tag)
    User.create!(email: "#{tag}-#{SecureRandom.hex(4)}@example.com", first_name: tag, last_name: 'User',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end

  def headers_for(user) = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }

  def ids = Array(JSON.parse(response.body).then { |j| j['items'] || j['deals'] }).map { |d| d['id'] }

  before do
    allow_any_instance_of(Api::Crm::DealsController).to receive(:authorize_action!).and_return(true)
  end

  it "lists another rep's deal on the account page" do
    get '/api/crm/deals', params: { account_id: account.id }, headers: headers_for(viewer)

    expect(ids).to eq([deal.id])
  end

  it "lists another rep's deal on the contact page" do
    get '/api/crm/deals', params: { contact_id: contact.id }, headers: headers_for(viewer)

    expect(ids).to eq([deal.id])
  end

  it 'keeps the main Deals list on My Deals by default' do
    get '/api/crm/deals', headers: headers_for(viewer)

    expect(ids).to be_empty
  end
end
