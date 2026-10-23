# frozen_string_literal: true

require 'rails_helper'

# Factory Direct's form asked its own "Name" question instead of Facebook's
# built-in full name, and 33 leads came in nameless with the name in the notes.
RSpec.describe FacebookLeads::LeadBuilder do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:owner) do
    User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'Olive', last_name: 'Owner',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:mapping) { {} }
  let(:integration) do
    FacebookIntegration.create!(company: company, page_id: 'page-1', page_name: 'Factory Direct Homes Center',
                                page_access_token: 'token', status: 'active', default_owner_id: owner.id, field_mapping: mapping)
  end

  def build(fields)
    raw = { 'field_data' => fields.map { |name, value| { 'name' => name, 'values' => [value] } } }
    described_class.new(integration, company).build(raw, leadgen_id: 'lg-1')
  end

  it "fills the name from a form's own Name question" do
    result = build('name' => 'Melinda  Bratcher', 'email' => 'mb@example.com')
    expect(result.attrs).to include(first_name: 'Melinda', last_name: 'Bratcher')
  end

  it 'reads a built-in field however Facebook spells the key' do
    result = build('Full Name' => 'Julie Rhodes', 'Phone Number' => '555-0100')
    expect(result.attrs).to include(first_name: 'Julie', last_name: 'Rhodes', phone: '555-0100')
  end

  context "when the dealer's mapping key carries punctuation Facebook dropped" do
    let(:mapping) { { 'How many bedrooms?' => 'preferred_bedrooms' } }

    it 'still routes the answer' do
      expect(build('how many bedrooms' => '3+').attrs).to include(preferred_bedrooms: '3+')
    end
  end
end
