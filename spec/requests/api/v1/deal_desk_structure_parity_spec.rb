# frozen_string_literal: true

require 'rails_helper'

# Solve, the payment grid and Compare must price the SAME deal the Recap shows. They used to
# be sent a base structure rebuilt in the browser that left out the scenario's add-on lines
# (delivery, set-up, skirting...), so Solve promised a payment the Recap then missed, the grid
# cell for the current term and down disagreed with the Recap, and Compare priced every home at
# 180 months with no F&I, add-ons or rebates. With scenario_id they all run on the scenario's
# own engine_inputs.
RSpec.describe 'Api::V1 Deal Desk structure parity (Recap, Solve, grid, Compare)', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing')
  end
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }

  def home(serial:, price:, cost:)
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: serial,
                             bedrooms: 3, bathrooms: 2.0, sale_price: price, dealer_cost: cost,
                             location_id: location.id, date_in_stock: 30.days.ago)
  end

  let!(:unit) { home(serial: "SN-#{SecureRandom.hex(4)}", price: 110_000, cost: 80_000) }
  # A comparable home with its own included package (porch), so Compare has to swap the
  # home's package lines and not just its price.
  let!(:other_unit) do
    v = home(serial: "SN-#{SecureRandom.hex(4)}", price: 105_000, cost: 76_000)
    v.inventory_packages.create!(name: 'Covered porch', price: 4_000, cost: 2_500, include_in_total: true)
    v
  end

  let(:deal) do
    d = company.deals.create!(name: 'Parity Deal', account: account, vehicle: unit, location_id: location.id)
    # The add-on lines the filming run caught missing from Solve and the grid.
    d.deal_products.create!(product_name: 'Delivery', unit_price: 3_500, cost: 2_800, quantity: 1, discount: 0, discount_type: 'fixed')
    d.deal_products.create!(product_name: 'Set-up', unit_price: 4_000, cost: 3_000, quantity: 1, discount: 0, discount_type: 'fixed')
    d.deal_products.create!(product_name: 'Skirting', unit_price: 1_100, cost: 700, quantity: 2, discount: 0, discount_type: 'fixed')
    d
  end

  before { company.tenant_module_overrides.create!(module_key: 'sales.deal_desk', is_enabled: true) }

  def json = JSON.parse(response.body)

  def create_scenario(attrs = {})
    post '/api/v1/deal_desk/scenarios',
         params: { scenario: { deal_id: deal.id, vehicle_id: unit.id, term_months: 240, cash_down: 0,
                               apr_override: 8.5, tax_rate: 0.05, tax_mode: 'full_price',
                               rebates: 1_000, trade_allowance: 6_000, trade_payoff: 2_000,
                               fees: { doc: 599 },
                               fni_products: [{ name: 'Service contract', type: 'service', price: 1_800, cost: 900 }] }
                   .merge(attrs) }.to_json,
         headers: headers
    expect(response).to have_http_status(:created)
    json['scenario']
  end

  def patch_scenario(id, attrs)
    patch "/api/v1/deal_desk/scenarios/#{id}", params: { scenario: attrs }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    json['scenario']
  end

  # What the browser used to send (scenarioToBaseStructure): no line_items, no pack.
  def browser_base_structure(s)
    {
      trade_allowance: s['trade_allowance'], trade_payoff: s['trade_payoff'], cash_down: s['cash_down'],
      rebates: s['rebates'], fees: s['fees'], fni_products: s['fni_products'], tax_rate: s['tax_rate'],
      tax_mode: s['tax_mode'], apr: s['apr'], term_months: s['term_months'],
      price: s['unit_price_snapshot'], unit_cost: s['unit_cost_snapshot']
    }
  end

  it 'snapshots the add-on lines onto the scenario (precondition)' do
    s = create_scenario
    expect(s['line_items'].sum { |li| li['price'].to_f * li['quantity'].to_f }).to eq(9_700.0)
  end

  describe 'Solve' do
    it 'by term: the applied answer equals the Recap and stays at or under the target' do
      s = create_scenario
      recap = s['monthly_payment'].to_f
      # Above the 240-month Recap, so a shorter term can meet it.
      target = (recap + 60).round(2)

      # The old browser structure (no add-on lines) solved to a payment the Recap would miss.
      post '/api/v1/deal_desk/scenarios/solve',
           params: { deal_id: deal.id, base_structure: browser_base_structure(s), lever: 'term',
                     target_payment: target }.to_json, headers: headers
      old = json['solve']

      post '/api/v1/deal_desk/scenarios/solve',
           params: { deal_id: deal.id, scenario_id: s['id'], lever: 'term', target_payment: target }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      solved = json['solve']
      expect(solved['met']).to be(true)

      applied = patch_scenario(s['id'], term_months: solved['term_months'])
      expect(applied['monthly_payment'].to_f).to be_within(0.01).of(solved['monthly_payment'].to_f)
      expect(applied['monthly_payment'].to_f).to be <= target

      # Document the bug: the old path promised a shorter term that, applied, lands over target.
      expect(old['met']).to be(true)
      expect(old['term_months']).to be < solved['term_months']
      old_applied = patch_scenario(s['id'], term_months: old['term_months'])
      expect(old_applied['monthly_payment'].to_f).to be > target
      puts "\n[parity] recap@240=#{recap} target=#{target} | old solve: #{old['term_months']} mo #{old['monthly_payment']} " \
           "-> Recap after apply #{old_applied['monthly_payment']} | new solve: #{solved['term_months']} mo " \
           "#{solved['monthly_payment']} -> Recap after apply #{applied['monthly_payment']}" if ENV['PARITY_NUMBERS']
    end

    it 'by cash down: the applied answer equals the Recap' do
      s = create_scenario
      target = (s['monthly_payment'].to_f - 100).round(2)

      post '/api/v1/deal_desk/scenarios/solve',
           params: { deal_id: deal.id, scenario_id: s['id'], lever: 'cash_down', target_payment: target }.to_json,
           headers: headers
      solved = json['solve']
      expect(solved['met']).to be(true)

      applied = patch_scenario(s['id'], cash_down: solved['cash_down'])
      expect(applied['monthly_payment'].to_f).to be_within(0.01).of(solved['monthly_payment'].to_f)
      expect(applied['monthly_payment'].to_f).to be <= target + 0.01
    end

    it 'refuses a scenario from another deal' do
      s = create_scenario
      other_deal = company.deals.create!(name: 'Other', account: account, vehicle: unit, location_id: location.id)
      post '/api/v1/deal_desk/scenarios/solve',
           params: { deal_id: other_deal.id, scenario_id: s['id'], lever: 'term', target_payment: 900 }.to_json,
           headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'payment grid' do
    it 'the cell at the scenario term and down equals the Recap' do
      s = create_scenario
      post '/api/v1/deal_desk/scenarios/grid',
           params: { deal_id: deal.id, scenario_id: s['id'], terms: [180, 240], cash_downs: [0, 5_000] }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      cell = json['grid']['cells'].find { |c| c['term_months'] == 240 && c['cash_down'].to_f.zero? }
      expect(cell['monthly_payment'].to_f).to be_within(0.01).of(s['monthly_payment'].to_f)
      expect(cell['out_the_door'].to_f).to be_within(0.01).of(s['out_the_door'].to_f)

      next unless ENV['PARITY_NUMBERS']

      post '/api/v1/deal_desk/scenarios/grid',
           params: { deal_id: deal.id, base_structure: browser_base_structure(s), terms: [240], cash_downs: [0] }.to_json,
           headers: headers
      puts "\n[parity] grid 240/$0: old #{json['grid']['cells'][0]['monthly_payment']} new #{cell['monthly_payment']} recap #{s['monthly_payment']}"
    end
  end

  describe 'Compare' do
    def compare(scenario_id, target: nil)
      post '/api/v1/deal_desk/scenarios/compare',
           params: { deal_id: deal.id, scenario_id: scenario_id, target_payment: target }.compact.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      json['compare']
    end

    it "prices the deal's own home on the open scenario, equal to the Recap" do
      s = create_scenario
      result = compare(s['id'])
      expect(result['anchor']['monthly_payment'].to_f).to be_within(0.01).of(s['monthly_payment'].to_f)
      expect(result['anchor']['out_the_door'].to_f).to be_within(0.01).of(s['out_the_door'].to_f)

      next unless ENV['PARITY_NUMBERS']

      post '/api/v1/deal_desk/scenarios/compare', params: { deal_id: deal.id }.to_json, headers: headers
      puts "\n[parity] compare own home: old #{json['compare']['anchor']['monthly_payment']} " \
           "new #{result['anchor']['monthly_payment']} recap #{s['monthly_payment']}"
    end

    it 'follows the scenario term instead of a fixed 180 months' do
      s = create_scenario(term_months: 120)
      result = compare(s['id'])
      expect(result['anchor']['monthly_payment'].to_f).to be_within(0.01).of(s['monthly_payment'].to_f)
    end

    it 'prices a candidate with the same structure plus its own packages, equal to the Recap after Use this unit' do
      s = create_scenario
      row = compare(s['id'])['candidates'].find { |c| c['vehicle_id'] == other_unit.id }
      expect(row).to be_present

      swapped = patch_scenario(s['id'], vehicle_id: other_unit.id)
      expect(row['monthly_payment'].to_f).to be_within(0.01).of(swapped['monthly_payment'].to_f)
      expect(row['out_the_door'].to_f).to be_within(0.01).of(swapped['out_the_door'].to_f)
    end

    it 'judges meets_target on the scenario structure' do
      s = create_scenario
      recap = s['monthly_payment'].to_f
      expect(compare(s['id'], target: recap - 1)['anchor']['meets_target']).to be(false)
      expect(compare(s['id'], target: recap)['anchor']['meets_target']).to be(true)
    end
  end

  describe 'Compare on a deal with no inventory home (custom or factory order)' do
    let(:custom_deal) do
      company.deals.create!(name: 'TrueBuild Deal', account: account, location_id: location.id,
                            selling_price: 140_000)
    end

    it 'answers 422 with a plain message instead of a 500' do
      post '/api/v1/deal_desk/scenarios', params: { scenario: { deal_id: custom_deal.id, term_months: 240 } }.to_json,
                                          headers: headers
      expect(response).to have_http_status(:created)
      sid = json['scenario']['id']

      [{ deal_id: custom_deal.id, scenario_id: sid }, { deal_id: custom_deal.id }].each do |body|
        post '/api/v1/deal_desk/scenarios/compare', params: body.to_json, headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json['error']).to include('custom or factory order')
        expect(json['error']).not_to match(/[–—]/)
      end
    end
  end
end
