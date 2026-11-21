# frozen_string_literal: true

require 'rails_helper'

# Floor plan homes (2026-11-20): one list of the homes on floor plan, the
# in-stock homes that are not, and tracking started, changed or stopped from it.
RSpec.describe 'Floor plan homes', type: :request do
  let(:company) { create(:company, industry: 'manufactured_housing') }
  let(:other_company) { create(:company, industry: 'manufactured_housing') }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:dealer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def body = JSON.parse(response.body)

  def home(co = company, **attrs)
    co.vehicles.create!({ listing_type: 'manufactured_home', make: 'Clayton', model: 'Tulip', year: 2026, status: 'available',
                          serial_number: "S-#{SecureRandom.hex(3)}", bedrooms: 3, bathrooms: 2, location_id: (co == company ? location.id : nil) }.merge(attrs))
  end

  before do
    AccountingSettings.for_company(company).update!(floor_plan_tracking_enabled: true, default_floor_plan_rate: 8.25,
                                                    default_floor_plan_lender: '21st Floor Plan')
  end

  describe 'GET /api/v1/accounting/floor_plan_homes' do
    it 'lists tracked homes, in-stock homes that are not, and flags homes set up halfway' do
      tracked = home(stock_number: 'T1', floor_plan_amount: 80_000, floor_plan_rate: 9, floor_plan_start_date: Date.current - 10)
      no_rate = home(stock_number: 'T2', floor_plan_amount: 50_000, floor_plan_start_date: Date.current - 3)
      no_rate.update_columns(floor_plan_rate: nil)
      untracked = home(stock_number: 'U1', total_cost: 61_500, date_in_stock: Date.current - 5)
      home(stock_number: 'SOLD', status: 'sold')
      home(stock_number: 'ORDER', status: 'ordered')
      home(stock_number: 'GONE', is_deleted: true, floor_plan_amount: 10_000, floor_plan_rate: 9)
      home(other_company, stock_number: 'OTHER')

      get '/api/v1/accounting/floor_plan_homes', headers: headers

      expect(response).to have_http_status(:ok)
      expect(body['tracked'].map { |r| r['stock_number'] }).to contain_exactly('T1', 'T2')
      expect(body['untracked'].map { |r| r['stock_number'] }).to eq(['U1'])
      row = body['tracked'].find { |r| r['vehicle_id'] == tracked.id }
      expect(row).to include('principal' => 80_000.0, 'rate' => 9.0, 'days_on_plan' => 10, 'problems' => [])
      expect(body['tracked'].find { |r| r['vehicle_id'] == no_rate.id }['problems']).to eq(['no_rate'])
      expect(body['untracked'].first).to include('vehicle_id' => untracked.id, 'suggested_amount' => 61_500.0,
                                                 'suggested_start_date' => (Date.current - 5).iso8601)
      expect(body['summary']).to include('tracked_count' => 2, 'untracked_count' => 1, 'needs_setup_count' => 1)
      expect(body['defaults']).to include('tracking_enabled' => true, 'rate' => 8.25, 'lender' => '21st Floor Plan')
    end

    it 'gives the counts the settings card shows' do
      home(floor_plan_amount: 80_000, floor_plan_rate: 9, floor_plan_start_date: Date.current)
      home
      home

      get '/api/v1/accounting/floor_plan_homes/summary', headers: headers

      expect(body).to include('tracked_count' => 1, 'untracked_count' => 2, 'needs_setup_count' => 0)
    end

    it 'shows a person only the homes at their locations' do
      mine = home(stock_number: 'MINE')
      elsewhere = company.locations.create!(name: 'Other lot')
      home(stock_number: 'THEIRS', location_id: elsewhere.id)
      allow_any_instance_of(User).to receive(:uses_rbac?).and_return(true)
      allow_any_instance_of(User).to receive(:effective_admin?).and_return(false)
      allow_any_instance_of(PermissionService).to receive(:accessible_location_ids).and_return([location.id])
      allow_any_instance_of(ApplicationController).to receive(:authorize_action!).and_return(true)

      get '/api/v1/accounting/floor_plan_homes', headers: headers

      expect(body['untracked'].map { |r| r['vehicle_id'] }).to eq([mine.id])
    end
  end

  describe 'POST /api/v1/accounting/floor_plan_homes' do
    it 'starts tracking, filling the rate and lender from the defaults' do
      a = home
      b = home

      post '/api/v1/accounting/floor_plan_homes', headers: headers, params: {
        homes: [{ vehicle_id: a.id, amount: '64,000', start_date: (Date.current - 2).iso8601 },
                { vehicle_id: b.id, amount: 70_000, rate: 7.5, lender: 'Triad' }]
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(body['saved']).to eq(2)
      expect(a.reload).to have_attributes(floor_plan_amount: 64_000, floor_plan_rate: 8.25, floor_plan_lender: '21st Floor Plan',
                                          floor_plan_start_date: Date.current - 2)
      expect(b.reload).to have_attributes(floor_plan_amount: 70_000, floor_plan_rate: 7.5, floor_plan_lender: 'Triad',
                                          floor_plan_start_date: Date.current)
    end

    it 'says which homes could not be saved and why' do
      good = home
      bad = home

      post '/api/v1/accounting/floor_plan_homes', headers: headers, params: {
        homes: [{ vehicle_id: good.id, amount: 60_000 }, { vehicle_id: bad.id, amount: '' }]
      }.to_json

      expect(body['saved']).to eq(1)
      expect(body['failed']).to eq([{ 'vehicle_id' => bad.id, 'ok' => false, 'error' => 'Enter the amount the lender advanced on this home.' }])
      expect(bad.reload.floor_plan_amount).to be_nil
    end

    it 'refuses a future start date and a rate typed as a fraction of a whole' do
      v = home

      post '/api/v1/accounting/floor_plan_homes', headers: headers,
                                                  params: { homes: [{ vehicle_id: v.id, amount: 60_000, start_date: (Date.current + 3).iso8601 }] }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['failed'].first['error']).to eq('The start date cannot be in the future.')

      post '/api/v1/accounting/floor_plan_homes', headers: headers,
                                                  params: { homes: [{ vehicle_id: v.id, amount: 60_000, rate: 850 }] }.to_json
      expect(body['failed'].first['error']).to start_with('The rate looks wrong')
    end

    it 'cannot touch another company\'s home' do
      theirs = home(other_company)

      post '/api/v1/accounting/floor_plan_homes', headers: headers, params: { homes: [{ vehicle_id: theirs.id, amount: 60_000 }] }.to_json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['failed'].first['error']).to eq('Home not found.')
      expect(theirs.reload.floor_plan_amount).to be_nil
    end
  end

  describe 'PATCH and DELETE /api/v1/accounting/floor_plan_homes/:id' do
    it 'changes a tracked home' do
      v = home(floor_plan_amount: 80_000, floor_plan_rate: 9, floor_plan_start_date: Date.current - 30, floor_plan_lender: 'Old')

      patch "/api/v1/accounting/floor_plan_homes/#{v.id}", headers: headers, params: { rate: 9.75, lender: 'New', amount: 78_000 }.to_json

      expect(response).to have_http_status(:ok)
      expect(v.reload).to have_attributes(floor_plan_rate: 9.75, floor_plan_lender: 'New', floor_plan_amount: 78_000,
                                          floor_plan_start_date: Date.current - 30)
    end

    it 'stops tracking without recording a payoff, keeping the rate and lender' do
      v = home(floor_plan_amount: 80_000, floor_plan_rate: 9, floor_plan_start_date: Date.current - 30, floor_plan_lender: 'Triad')

      delete "/api/v1/accounting/floor_plan_homes/#{v.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(v.reload).to have_attributes(floor_plan_amount: nil, floor_plan_start_date: nil, floor_plan_rate: 9, floor_plan_lender: 'Triad',
                                          floor_plan_curtailed_at: nil)
    end

    it 'will not change a home that was paid off' do
      v = home(floor_plan_amount: 80_000, floor_plan_rate: 9, floor_plan_start_date: Date.current - 30)
      v.update_columns(floor_plan_curtailed_at: Date.current)

      patch "/api/v1/accounting/floor_plan_homes/#{v.id}", headers: headers, params: { amount: 5_000 }.to_json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to include('paid off')
    end
  end
end
