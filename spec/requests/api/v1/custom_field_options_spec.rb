# frozen_string_literal: true

require 'rails_helper'

# Free-typed categories turned into 44 spellings of about 8 things. A dropdown
# people can add to keeps the choice theirs without bringing the spellings back.
RSpec.describe 'POST /api/v1/custom_fields/:id/options', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }

  def field(module_name: 'leads', target: company, allow: true, field_type: 'select', options: %w[Dealer Supplier])
    CustomField.create!(company: target, module: module_name, name: 'Category', field_key: 'category', field_type: field_type,
                        options: options, validation_rules: { 'allow_new_options' => allow })
  end

  def add(custom_field, option)
    post "/api/v1/custom_fields/#{custom_field.id}/options", params: { option: option }.to_json, headers: headers
    JSON.parse(response.body)
  end

  it 'adds the choice and returns it' do
    leads = field
    expect(add(leads, '  Modular   Builder ')['option']).to eq('Modular Builder')
    expect(leads.reload.options).to eq(['Dealer', 'Supplier', 'Modular Builder'])
  end

  it 'returns the existing spelling instead of adding a near duplicate' do
    leads = field
    expect(add(leads, 'dealer')['option']).to eq('Dealer')
    expect(leads.reload.options).to eq(%w[Dealer Supplier])
  end

  it 'adds to the same field on other record types, but not to one without the setting' do
    leads = field
    accounts = field(module_name: 'accounts')
    deals = field(module_name: 'deals', allow: false)
    add(leads, 'Installer')

    expect(accounts.reload.options).to include('Installer')
    expect(deals.reload.options).not_to include('Installer')
  end

  it 'asks for the permission that guards the record type' do
    accounts = field(module_name: 'accounts')
    allow_any_instance_of(Api::V1::CustomFieldsController).to receive(:can?) { |_, resource, _action| resource == 'crm' }
    add(accounts, 'Installer')
    expect(response).to have_http_status(:ok)

    allow_any_instance_of(Api::V1::CustomFieldsController).to receive(:can?).and_return(false)
    add(accounts, 'Other')
    expect(response).to have_http_status(:forbidden)
    expect(accounts.reload.options).not_to include('Other')
  end

  it 'refuses a field without the setting' do
    leads = field(allow: false)
    add(leads, 'Installer')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(leads.reload.options).not_to include('Installer')
  end

  it 'refuses a blank or overlong choice' do
    leads = field
    add(leads, '   ')
    expect(response).to have_http_status(:unprocessable_entity)
    add(leads, 'x' * 101)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "cannot reach another company's field" do
    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
    theirs = field(target: other)
    add(theirs, 'Installer')
    expect(response).to have_http_status(:not_found)
    expect(theirs.reload.options).not_to include('Installer')
  end

  it 'accepts a value not on the list only when the field allows new choices' do
    expect(field.validate_value('From an import')).to be_empty
    other = CustomField.create!(company: company, module: 'leads', name: 'Plain', field_key: 'plain',
                                field_type: 'select', options: %w[A])
    expect(other.validate_value('From an import')).not_to be_empty
    expect(other.allow_new_options?).to be(false)
  end

  it 'field definitions tell the form the field can be added to' do
    field
    get '/api/v1/page_layouts/leads/field_definitions', headers: headers
    definition = JSON.parse(response.body)['field_definitions'].find { |f| f['key'] == 'category' }
    expect(definition['allow_new_options']).to be(true)
  end
end
