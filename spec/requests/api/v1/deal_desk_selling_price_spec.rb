# frozen_string_literal: true

require 'rails_helper'

# Deal Desk may change the home's selling price (Tom, 2026-11-13). The price is set on the
# scenario (selling_price_override) and the Recap, Solve, the payment grid and Compare all
# price that same deal. Apply to Deal writes it to the deal's home line, which is what the
# deal's selling_price, value and front gross read.
RSpec.describe 'Api::V1 Deal Desk selling price', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { auth_headers(user) }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }

  let!(:unit) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 110_000, dealer_cost: 80_000,
                             location_id: location.id, date_in_stock: 30.days.ago)
  end

  # The deal's home line is the deal's authoritative home price: selling_price mirrors it.
  let(:deal) do
    d = company.deals.create!(name: 'Price Deal', account: account, vehicle: unit, location_id: location.id)
    d.deal_products.create!(product_name: '2024 Fleetwood Aspire', unit_price: 110_000, cost: 80_000, quantity: 1,
                            discount: 0, discount_type: 'fixed', notes: 'category:home')
    d.deal_products.create!(product_name: 'Delivery', unit_price: 3_500, cost: 2_800, quantity: 1,
                            discount: 0, discount_type: 'fixed', notes: 'category:service')
    d.reload
  end

  before { company.tenant_module_overrides.create!(module_key: 'sales.deal_desk', is_enabled: true) }

  def auth_headers(u)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  def json = JSON.parse(response.body)

  def create_scenario(attrs = {}, as: headers)
    post '/api/v1/deal_desk/scenarios',
         params: { scenario: { deal_id: deal.id, vehicle_id: unit.id, term_months: 240, cash_down: 5_000,
                               apr_override: 8.5, tax_rate: 0.05, tax_mode: 'full_price', fees: { doc: 599 } }
                   .merge(attrs) }.to_json,
         headers: as
    expect(response).to have_http_status(:created)
    json['scenario']
  end

  def patch_scenario(id, attrs, as: headers)
    patch "/api/v1/deal_desk/scenarios/#{id}", params: { scenario: attrs }.to_json, headers: as
    expect(response).to have_http_status(:ok)
    json['scenario']
  end

  it 'a selling price on the scenario changes the payment, and the Recap shows list, selling and discount' do
    s = create_scenario
    expect(s['unit_price_snapshot']).to eq(110_000.0)
    expect(s['selling_price']).to eq(110_000.0)
    expect(s['selling_price_override']).to be_nil
    list_payment = s['monthly_payment'].to_f

    priced = patch_scenario(s['id'], { selling_price_override: 102_500 })
    expect(priced['selling_price']).to eq(102_500.0)
    expect(priced['unit_price_snapshot']).to eq(110_000.0)
    expect(priced['price_discount']).to eq(7_500.0)
    expect(priced['monthly_payment'].to_f).to be < list_payment
    # Out the door moves by the discount plus the tax on it (full-price tax mode).
    expect(priced['out_the_door'].to_f).to be_within(0.01).of(s['out_the_door'].to_f - 7_500 * 1.05)

    # The engine run on the scenario's own inputs is the Recap.
    scenario = DealDeskScenario.find(s['id'])
    expect(scenario.engine_inputs[:price].to_f).to eq(102_500.0)
    expect(scenario.engine_result.monthly_payment).to be_within(0.01).of(priced['monthly_payment'].to_f)

    # Clearing it puts the home back at list.
    cleared = patch_scenario(s['id'], { selling_price_override: nil })
    expect(cleared['selling_price']).to eq(110_000.0)
    expect(cleared['monthly_payment'].to_f).to be_within(0.01).of(list_payment)
  end

  it 'Solve by price, applied as the selling price, equals the Recap; the grid and Compare agree' do
    s = create_scenario
    target = (s['monthly_payment'].to_f - 40).round(2)

    post '/api/v1/deal_desk/scenarios/solve',
         params: { deal_id: deal.id, scenario_id: s['id'], lever: 'price', target_payment: target }.to_json,
         headers: headers
    expect(response).to have_http_status(:ok)
    solved = json['solve']
    expect(solved['met']).to be(true)
    expect(solved['list_price']).to eq(110_000.0)
    expect(solved['discount']).to be_within(0.01).of(110_000 - solved['price'].to_f)

    applied = patch_scenario(s['id'], { selling_price_override: solved['price'] })
    expect(applied['selling_price']).to eq(solved['price'].to_f)
    expect(applied['monthly_payment'].to_f).to be_within(0.01).of(solved['monthly_payment'].to_f)
    expect(applied['monthly_payment'].to_f).to be <= target

    # Solving again from the new price reports the discount from list, not from the desk price.
    post '/api/v1/deal_desk/scenarios/solve',
         params: { deal_id: deal.id, scenario_id: s['id'], lever: 'price', target_payment: target - 20 }.to_json,
         headers: headers
    expect(json['solve']['discount']).to be_within(0.01).of(110_000 - json['solve']['price'].to_f)

    post '/api/v1/deal_desk/scenarios/grid',
         params: { deal_id: deal.id, scenario_id: s['id'], terms: [240], cash_downs: [5_000] }.to_json,
         headers: headers
    expect(json['grid']['cells'].first['monthly_payment'].to_f).to be_within(0.01).of(applied['monthly_payment'].to_f)

    post '/api/v1/deal_desk/scenarios/compare',
         params: { deal_id: deal.id, scenario_id: s['id'] }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    anchor = json['compare']['anchor']
    expect(anchor['monthly_payment'].to_f).to be_within(0.01).of(applied['monthly_payment'].to_f)
    expect(anchor['sale_price'].to_f).to eq(solved['price'].to_f)
  end

  it 'Apply to Deal writes the selling price to the home line, the deal price and value, and the history' do
    s = create_scenario
    patch_scenario(s['id'], { selling_price_override: 104_000 })
    value_before = deal.reload.value.to_f
    expect(deal.selling_price.to_f).to eq(110_000.0)

    post "/api/v1/deal_desk/scenarios/#{s['id']}/apply", headers: headers
    expect(response).to have_http_status(:ok)
    expect(json['price_change']).to eq('from' => 110_000.0, 'to' => 104_000.0)

    deal.reload
    home = deal.home_line_item
    expect(home.unit_price.to_f).to eq(104_000.0)
    expect(deal.selling_price.to_f).to eq(104_000.0)
    expect(deal.home_line_item_price).to eq(104_000.0)
    # Value is the line total: it drops by the discount (the doc fee line added by Apply
    # rides on top of it).
    doc = deal.deal_products.detect { |dp| dp.product_name == 'Doc Fee' }
    expect(deal.value.to_f).to eq(value_before - 6_000 + doc.total.to_f)
    # Gross is the deal's own (Deal#front_gross), read off the new home price: home margin
    # plus the add-on margins (delivery 700, the doc fee line 599).
    expect(deal.front_gross).to eq((104_000 - deal.landed_cost + 700 + 599).round(2))

    log = ActivityLog.where(trackable: deal).order(:id).detect { |l| l.description.to_s.include?('Home selling price') }
    expect(log).to be_present
    expect(log.description).to include('$110,000.00', '$104,000.00', 'Deal Desk')
    expect(log.user_id).to eq(user.id)

    # The scenario does not flag the deal's price as moved: it is the scenario's own price.
    get "/api/v1/deal_desk/scenarios/#{s['id']}", headers: headers
    expect(json['scenario']['price_changed']).to be(false)

    # Applying again changes nothing.
    post "/api/v1/deal_desk/scenarios/#{s['id']}/apply", headers: headers
    expect(json['price_change']).to be_nil
    expect(deal.reload.selling_price.to_f).to eq(104_000.0)
  end

  it 'the buyer pencil and package price the home at the selling price' do
    s = create_scenario
    patch_scenario(s['id'], { selling_price_override: 103_000 })
    scenario = DealDeskScenario.find(s['id'])

    get "/api/v1/deal_desk/scenarios/#{s['id']}/summary", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/pdf')

    snap = DealDesk::ShareSnapshotBuilder.new(deal: deal, scenarios: [scenario], vehicle_payload: {}).send(:scenario_customer_json, scenario)
    expect(snap['unit_price_snapshot']).to eq(103_000.0)
    expect(snap['list_price']).to eq(110_000.0)
    expect(snap['monthly_payment']).to be_within(0.01).of(scenario.reload.monthly_payment.to_f)
  end

  it 'keeps the home line discount and nets the line to the selling price' do
    deal.home_line_item.update!(unit_price: 112_000, discount: 2_000, discount_type: 'fixed')
    s = create_scenario
    expect(s['unit_price_snapshot']).to eq(110_000.0)
    patch_scenario(s['id'], { selling_price_override: 107_000 })

    post "/api/v1/deal_desk/scenarios/#{s['id']}/apply", headers: headers
    expect(response).to have_http_status(:ok)
    home = deal.reload.home_line_item
    expect(home.discount.to_f).to eq(2_000.0)
    expect(home.unit_price.to_f).to eq(109_000.0)
    expect(deal.selling_price.to_f).to eq(107_000.0)
  end

  it 'a new home on the scenario starts at its own price' do
    other = company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                                     make: 'Fleetwood', model: 'Other', serial_number: "SN-#{SecureRandom.hex(4)}",
                                     bedrooms: 3, bathrooms: 2.0, sale_price: 99_000, dealer_cost: 70_000,
                                     location_id: location.id, date_in_stock: 30.days.ago)
    s = create_scenario
    patch_scenario(s['id'], { selling_price_override: 100_000 })
    swapped = patch_scenario(s['id'], { vehicle_id: other.id })
    expect(swapped['selling_price_override']).to be_nil
    expect(swapped['selling_price']).to eq(swapped['unit_price_snapshot'])
  end

  describe 'permissions' do
    let(:rbac_company) { company.tap { |c| c.update!(use_rbac_system: true) } }

    def rep_headers(deal_actions)
      Resource.seed_defaults
      Action.seed_defaults
      Scope.seed_defaults
      rep = User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P',
                         password: 'Pass1234!', company_id: rbac_company.id, role: 'user')
      role = Role.create!(company_id: company.id, key: "rep-#{SecureRandom.hex(3)}", name: 'Rep', tier: 'company', active: true)
      all = Scope.find_by!(key: 'all')
      %w[read write].each do |a|
        RolePermission.create!(role: role, resource: Resource.find_by!(key: 'deal_desk'), action: Action.find_by!(key: a), scope: all)
      end
      deal_actions.each do |a|
        RolePermission.create!(role: role, resource: Resource.find_by!(key: 'deals'), action: Action.find_by!(key: a), scope: all)
      end
      rep.user_role_assignments.create!(role: role, company_id: company.id, tier: 'company')
      auth_headers(rep)
    end

    it 'a rep who cannot update deals may set a desk price but not apply it to the deal' do
      s = create_scenario
      rep = rep_headers(%w[read])
      patch_scenario(s['id'], { selling_price_override: 101_000 }, as: rep)

      post "/api/v1/deal_desk/scenarios/#{s['id']}/apply", headers: rep
      expect(response).to have_http_status(:forbidden)
      expect(deal.reload.selling_price.to_f).to eq(110_000.0)
      expect(deal.home_line_item.unit_price.to_f).to eq(110_000.0)
    end

    it 'a rep who can update deals applies it' do
      s = create_scenario
      rep = rep_headers(%w[read update])
      patch_scenario(s['id'], { selling_price_override: 101_000 }, as: rep)

      post "/api/v1/deal_desk/scenarios/#{s['id']}/apply", headers: rep
      expect(response).to have_http_status(:ok)
      expect(deal.reload.selling_price.to_f).to eq(101_000.0)
    end
  end
end
