# frozen_string_literal: true

require 'rails_helper'

# Agreement fields offer dropdowns fed from data: the home's feature lists and
# what the dealer entered before. Formulas get the deal's values from the builder.
RSpec.describe 'Agreement dropdown sources and deal-aware formulas', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:template) do
    company.agreement_templates.create!(
      name: 'PA', template_type: 'upload', status: 'active',
      custom_field_definitions: [
        { 'key' => 'cabinet_color', 'label' => 'Cabinet color', 'type' => 'text', 'options_from' => 'history' },
        { 'key' => 'upgrades', 'label' => 'Upgrades', 'type' => 'currency', 'formula' => '=sum(deal.line_items_accessory.line_total)' },
        { 'key' => 'total', 'label' => 'Total', 'type' => 'currency', 'formula' => '=deal.selling_price - discount + upgrades' }
      ]
    )
  end

  def option_lists(params)
    get '/api/v1/agreement_merge_fields', params: params, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body['option_lists']
  end

  it "suggests the dealer's past values for a history field, most used first" do
    %w[Espresso Espresso White].each do |color|
      company.agreements.create!(title: 'PA', agreement_template_id: template.id,
                                 custom_field_values: { 'cabinet_color' => color })
    end

    expect(option_lists(template_id: template.id)['history.cabinet_color']).to eq(%w[Espresso White])
  end

  it "offers the home's feature list" do
    home = company.vehicles.create!(make: 'Champion', model: 'Aspire', year: 2026, vin: "VIN#{SecureRandom.hex(4)}",
                                    features: ['Vinyl Siding', 'Garden Tub'])
    buyer = company.contacts.create!(first_name: 'Jeretta', last_name: 'Smuts')
    deal = company.deals.create!(name: 'Deal', vehicle_id: home.id, contact_id: buyer.id)

    lists = option_lists(deal_id: deal.id)
    expect(lists['vehicle.features']).to eq(['Vinyl Siding', 'Garden Tub'])
  end

  it 'calculates formulas from the deal values the builder sends' do
    post '/api/v1/agreements/preview_calculate', headers: headers, as: :json, params: {
      template_id: template.id,
      custom_field_values: { 'discount' => '8425' },
      merge_values: {
        'deal.selling_price' => '87489',
        'deal.line_items_accessory[0].line_total' => '179',
        'deal.line_items_accessory[1].line_total' => '1240',
        'not_a_merge_field' => '999999'
      }
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['calculated_values']).to eq('upgrades' => 1419.0, 'total' => 80_483.0)
  end
end
