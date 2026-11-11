# frozen_string_literal: true

require 'rails_helper'

# Tom 2026-11-10: a brochure's "Show Prices" switch did nothing; every
# brochure printed prices. Now the template's switch decides, a brochure can
# set its own, and hidden prices never reach the public page's data.
RSpec.describe 'Brochure show prices', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: 'One',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:vehicle) do
    company.vehicles.create!(year: 2024, make: 'Clayton', model: 'Rio', status: 'available', vin: "VIN#{SecureRandom.hex(6)}",
                             msrp: 88_000)
  end

  def brochure(show_in_template:, own: nil)
    blocks = [{ 'id' => 'g', 'type' => 'gallery', 'config' => { 'showPrices' => show_in_template }.compact }]
    Brochure.create!(company_id: company.id, title: 'Fall', status: 'active', is_public: true, vehicle_ids: [vehicle.id],
                     template_data: { 'blocks' => blocks }, show_prices: own)
  end

  def public_view(b)
    get "/b/#{b.public_id}"
    JSON.parse(response.body)['brochure']
  end

  it 'shows prices when the template never set the switch, as before' do
    data = public_view(brochure(show_in_template: nil))
    expect(data['showPrices']).to be(true)
    expect(data['vehicles'].first['msrp']).to eq(88_000.0)
  end

  it 'leaves every price out of the data when the template hides them, and the calculator too' do
    data = public_view(brochure(show_in_template: false))
    home = data['vehicles'].first
    expect(data['showPrices']).to be(false)
    expect(home.values_at('msrp', 'salePrice', 'totalHomePrice', 'totalPriceBeforeDiscount')).to all(be_nil)
    expect(data['calculatorSettings']['enabled']).to be(false)
    expect(response.body).not_to include('88000')
  end

  it "lets one brochure override its template either way, and clear back to the template" do
    hidden_by_template = brochure(show_in_template: false)
    put "/api/v1/brochures/#{hidden_by_template.id}", params: { brochure: { showPrices: true } }.to_json, headers: headers
    expect(JSON.parse(response.body)['brochure']).to include('showPrices' => true, 'showPricesOverride' => true, 'templateShowsPrices' => false)
    expect(public_view(hidden_by_template)['vehicles'].first['msrp']).to eq(88_000.0)

    put "/api/v1/brochures/#{hidden_by_template.id}", params: { brochure: { showPrices: 'template' } }.to_json, headers: headers
    expect(JSON.parse(response.body)['brochure']).to include('showPrices' => false, 'showPricesOverride' => nil)

    shown_by_template = brochure(show_in_template: true, own: false)
    expect(public_view(shown_by_template)['vehicles'].first['msrp']).to be_nil
  end

  it 'leaves the price off the email when the brochure hides prices' do
    vehicle.update!(sale_price: 77_000)
    shown = BrochureSendingService.new(brochure(show_in_template: true)).__send__(:build_email_body, custom_message: 'Hi')
    hidden = BrochureSendingService.new(brochure(show_in_template: false)).__send__(:build_email_body, custom_message: 'Hi')
    expect(shown).to include('$77000.00')
    expect(hidden).not_to include('$77000.00')
  end
end
