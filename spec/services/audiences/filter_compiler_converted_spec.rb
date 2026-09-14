# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Audiences::FilterCompiler, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  it 'lets an audience leave out leads that became deals' do
    open_lead = Lead.create!(company_id: company.id, first_name: 'Open', last_name: 'Lead', email: 'open@example.com')
    Lead.create!(company_id: company.id, first_name: 'Sold', last_name: 'Lead', email: 'sold@example.com',
                 is_converted: true, converted_at: Time.current)

    scope = described_class.new(company: company, source_type: 'Lead', channel: 'email',
                                filter_tree: { 'type' => 'and', 'children' => [
                                  { 'field' => 'is_converted', 'operator' => 'equals', 'value' => false }
                                ] }).scope

    expect(scope.pluck(:id)).to eq([open_lead.id])
  end
end
