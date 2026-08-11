# frozen_string_literal: true

require 'rails_helper'

# The mapping list the intake form builder offers was a hardcoded array of
# eleven standard columns, identical for every tenant. A dealer's own lead
# custom fields were never in it, so there was no way to map a form question
# to the field built to hold its answer.
RSpec.describe 'GET /api/crm/intake/forms/lead_fields', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:fields) { JSON.parse(response.body)['fields'] }
  def field_named(name) = fields.find { |f| f['name'] == name }

  before do
    company.custom_fields.create!(module: 'leads', name: 'Zebra Question', field_key: 'zebra_question',
                                  field_type: 'text', is_active: true)
    company.custom_fields.create!(module: 'leads', name: 'Are you financing?', field_key: 'financing',
                                  field_type: 'text', is_active: true)
  end

  it 'still returns the standard lead columns' do
    get '/api/crm/intake/forms/lead_fields', headers: headers

    expect(response).to have_http_status(:ok)
    expect(fields.map { |f| f['name'] }).to include('first_name', 'email', 'phone', 'notes')
  end

  it "includes the company's active lead custom fields, namespaced" do
    get '/api/crm/intake/forms/lead_fields', headers: headers

    financing = field_named('custom:financing')
    expect(financing).to be_present
    expect(financing['label']).to eq('Are you financing?')
    expect(financing['group']).to eq('Custom Fields')
  end

  it 'sorts the custom block alphabetically by label' do
    get '/api/crm/intake/forms/lead_fields', headers: headers

    custom_labels = fields.select { |f| f['group'] == 'Custom Fields' }.map { |f| f['label'] }
    expect(custom_labels).to eq(custom_labels.sort_by(&:downcase))
    expect(custom_labels.first).to eq('Are you financing?')
  end

  it 'leaves out deactivated fields and fields from other modules' do
    company.custom_fields.create!(module: 'leads', name: 'Retired', field_key: 'retired',
                                  field_type: 'text', is_active: false)
    company.custom_fields.create!(module: 'deals', name: 'Deal Only', field_key: 'deal_only',
                                  field_type: 'text', is_active: true)

    get '/api/crm/intake/forms/lead_fields', headers: headers

    expect(field_named('custom:retired')).to be_nil
    expect(field_named('custom:deal_only')).to be_nil
  end

  # The old list was a constant, so it could not leak across tenants. Now that
  # it reads from the database, tenant scoping is load-bearing.
  it "never exposes another company's custom fields" do
    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}", industry: 'manufactured_housing')
    other.custom_fields.create!(module: 'leads', name: 'Secret', field_key: 'secret',
                                field_type: 'text', is_active: true)

    get '/api/crm/intake/forms/lead_fields', headers: headers

    expect(field_named('custom:secret')).to be_nil
  end
end
