# frozen_string_literal: true

require 'rails_helper'

# Form 500 option rows the dealer adds or changes on the agreement are offered back
# to the deal, a "*" marks non-taxable rows and splits the totals, and boxes that
# exist only on the form carry to the next agreement on the same deal.
RSpec.describe 'Agreement changes back to the deal', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', first_name: 'A', last_name: 'B')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:buyer) { company.contacts.create!(first_name: 'Keia', last_name: 'Walker', email: 'k@example.com') }
  let(:deal) { company.deals.create!(name: 'Walker home', contact_id: buyer.id) }
  let!(:home_line) do
    deal.deal_products.create!(product_name: 'Home', quantity: 1, unit_price: 100_000, tax: 3000,
                               source_type: 'home', notes: 'category:home, source:home')
  end
  let!(:skirting) do
    deal.deal_products.create!(product_name: 'Skirting', quantity: 1, unit_price: 2000,
                               notes: 'category:service, source:standard_item, taxable:no')
  end
  let(:rows) do
    (0..3).flat_map do |i|
      %w[tax_mark description line_total].map do |col|
        { 'id' => "r#{i}#{col}", 'fieldKey' => "deal.line_items_options[#{i}].#{col}", 'fieldLabel' => col,
          'fieldType' => 'text', 'page' => 0, 'x' => 1, 'y' => 1, 'width' => 1, 'height' => 1 }
      end
    end
  end
  let(:template) do
    company.agreement_templates.create!(
      name: 'Form 500', template_type: 'upload', status: 'active', merge_field_placements: rows,
      custom_field_definitions: [
        { 'key' => 'hitch_size_l', 'label' => 'Hitch L', 'type' => 'text', 'merge_from' => 'vehicle.length' },
        { 'key' => 'key_numbers', 'label' => 'Key numbers', 'type' => 'text' },
        { 'key' => 'remarks', 'label' => 'Remarks', 'type' => 'text' },
        { 'key' => 'balance_carried', 'label' => 'Balance', 'type' => 'currency',
          'formula' => '=sum_unmarked(deal.line_items_options.line_total, deal.line_items_options.tax_mark)' },
        { 'key' => 'non_taxable_items', 'label' => 'Non-taxable', 'type' => 'currency',
          'formula' => '=sum_marked(deal.line_items_options.line_total, deal.line_items_options.tax_mark)' }
      ]
    )
  end

  def values_from_deal
    get '/api/v1/agreement_merge_fields', params: { deal_id: deal.id }, headers: headers
    response.parsed_body['line_item_values']
  end

  def agreement_with(values = {}, status: 'draft')
    company.agreements.create!(title: 'Form 500', status: status, deal_id: deal.id, agreement_template_id: template.id,
                               merge_field_placements: rows, merge_field_values: values)
  end

  def changes_for(agreement)
    get "/api/v1/agreements/#{agreement.id}/deal_changes", headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  it 'marks non-taxable rows with "*" and carries a ref to the deal line' do
    v = values_from_deal
    expect(v['deal.line_items_options[0].description']).to eq('Skirting')
    expect(v['deal.line_items_options[0].tax_mark']).to eq('*')
    expect(v['deal.line_items_options[0].ref']).to eq("dp:#{skirting.id}")
  end

  it 'totals marked rows to non-taxable and the rest to the balance carried' do
    values = {
      'deal.line_items_options[0].line_total' => '2000', 'deal.line_items_options[0].tax_mark' => '*',
      'deal.line_items_options[1].line_total' => '1500', 'deal.line_items_options[1].tax_mark' => '',
      'deal.line_items_options[2].line_total' => '928', 'deal.line_items_options[2].tax_mark' => '*'
    }
    result = FormulaEngine.new.evaluate(template.custom_field_definitions, {}, values)
    expect(result['balance_carried']).to eq(1500.0)
    expect(result['non_taxable_items']).to eq(2928.0)
  end

  it 'offers a row typed on a spare line, and adds it to the deal with tax at the deal rate' do
    values = values_from_deal.merge('deal.line_items_options[1].description' => 'Porch',
                                    'deal.line_items_options[1].line_total' => '1500')
    agreement = agreement_with(values)

    body = changes_for(agreement)
    expect(body['changes'].map { |c| c['id'] }).to eq(['add:line_items_options:1'])
    expect(body['changes'][0]['tax']).to eq(45.0)

    post "/api/v1/agreements/#{agreement.id}/deal_changes", params: { change_ids: ['add:line_items_options:1'] }, headers: headers
    expect(response).to have_http_status(:ok)
    porch = deal.deal_products.find_by(product_name: 'Porch')
    expect(porch.unit_price.to_f).to eq(1500.0)
    expect(porch.tax.to_f).to eq(45.0)
    expect(porch.notes).to include('category:accessory')
    expect(agreement.reload.merge_field_values['deal.line_items_options[1].ref']).to eq("dp:#{porch.id}")
    expect(changes_for(agreement)['changes']).to be_empty
  end

  it 'offers a changed price and a cleared "*", and updates the deal line' do
    values = values_from_deal.merge('deal.line_items_options[0].line_total' => '2200',
                                    'deal.line_items_options[0].tax_mark' => '')
    agreement = agreement_with(values)

    change = changes_for(agreement)['changes'].sole
    expect(change['id']).to eq("update:dp:#{skirting.id}")
    expect(change['was']['amount']).to eq(2000.0)

    post "/api/v1/agreements/#{agreement.id}/deal_changes", params: { change_ids: [change['id']] }, headers: headers
    skirting.reload
    expect(skirting.unit_price.to_f).to eq(2200.0)
    expect(skirting.notes).not_to include('taxable:no')
    expect(skirting.tax.to_f).to eq(66.0)
  end

  it 'matches rows saved before refs existed by description, so nothing is added twice' do
    agreement = agreement_with({ 'deal.line_items_options[0].description' => 'Skirting',
                                 'deal.line_items_options[0].line_total' => '2000',
                                 'deal.line_items_options[0].tax_mark' => '*' })
    expect(changes_for(agreement)['changes']).to be_empty
  end

  it 'never offers changes from a sent agreement' do
    values = values_from_deal.merge('deal.line_items_options[1].description' => 'Porch')
    body = changes_for(agreement_with(values, status: 'sent'))
    expect(body['changes']).to be_empty
    expect(body['blocked_reason']).to include('never change the deal')
  end

  it 'carries form-only boxes to the next agreement on the same deal' do
    agreement_with.update!(custom_field_values: { 'key_numbers' => 'A12', 'remarks' => 'Color per sheet',
                                                       'hitch_size_l' => '84', 'balance_carried' => 9 })

    get '/api/v1/agreement_merge_fields', params: { deal_id: deal.id, template_id: template.id }, headers: headers
    expect(response.parsed_body['carry_forward']).to eq('key_numbers' => 'A12', 'remarks' => 'Color per sheet')
  end
end
