# frozen_string_literal: true

require 'rails_helper'

# Regression: the Deals table sorted client-side over the loaded page only, so
# on a multi-page list clicking a header just rearranged the visible 50 rows.
RSpec.describe 'Deals server-side sorting', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:zoe)  { User.create!(email: "z-#{SecureRandom.hex(3)}@example.com", first_name: 'Zoe', last_name: 'Adams', password: 'Pass1234!', company_id: company.id) }
  let!(:adam) { User.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'Adam', last_name: 'Zeller', password: 'Pass1234!', company_id: company.id) }

  let!(:account) { company.accounts.create!(name: 'Acme Homes') }

  let!(:bravo) do
    company.deals.create!(name: 'Bravo', value: 200, owner_id: zoe.id, account_id: account.id,
                          last_activity_at: 2.days.ago, expected_close_date: Date.new(2026, 3, 1))
  end
  let!(:alpha) do
    company.deals.create!(name: 'Alpha', value: 300, owner_id: adam.id, account_id: account.id,
                          last_activity_at: 1.day.ago, expected_close_date: Date.new(2026, 1, 1))
  end
  let!(:charlie) do
    company.deals.create!(name: 'Charlie', value: 100, owner_id: nil, account_id: account.id,
                          last_activity_at: nil, expected_close_date: Date.new(2026, 2, 1))
  end

  def names_for(params)
    get '/api/crm/deals', params: params.merge(view: 'all'), headers: headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    items = body['deals'] || body['items'] || body
    items.map { |d| d['name'] }
  end

  it 'sorts by name ascending' do
    expect(names_for(sort_by: 'name', sort_dir: 'asc')).to eq(%w[Alpha Bravo Charlie])
  end

  it 'sorts by name descending' do
    expect(names_for(sort_by: 'name', sort_dir: 'desc')).to eq(%w[Charlie Bravo Alpha])
  end

  it 'sorts by value' do
    expect(names_for(sort_by: 'value', sort_dir: 'desc')).to eq(%w[Alpha Bravo Charlie])
  end

  it 'sorts by expected close date' do
    expect(names_for(sort_by: 'expectedCloseDate', sort_dir: 'asc')).to eq(%w[Alpha Charlie Bravo])
  end

  # Ordering by owner_id would look arbitrary next to a column showing names.
  it 'sorts owner by displayed name rather than id' do
    expect(names_for(sort_by: 'owner', sort_dir: 'asc').first(2)).to eq(%w[Alpha Bravo])
  end

  it 'sinks rows with no value for the sorted column' do
    # Charlie has no last_activity_at, so it must not lead an ascending sort.
    expect(names_for(sort_by: 'lastActivity', sort_dir: 'asc').last).to eq('Charlie')
  end

  it 'falls back to newest-first for an unknown column instead of erroring' do
    expect(names_for(sort_by: 'not_a_column; DROP TABLE deals')).to be_an(Array)
    expect(Deal.count).to eq(3)
  end

  it 'defaults to newest-first when no sort is given' do
    expect(names_for({})).to eq(%w[Charlie Alpha Bravo])
  end
end
