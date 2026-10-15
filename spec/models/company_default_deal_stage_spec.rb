# frozen_string_literal: true

require 'rails_helper'

# A stage is active unless it is turned off. Factory Direct's stages carried
# no flag; switching Qualified made it the only flagged one, and new deals
# started landing there.
RSpec.describe Company, '#default_deal_stage' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def stages(qualified_flag: :absent)
    qualified = { 'key' => 'qualified', 'name' => 'Qualified', 'order' => 1 }
    qualified['active'] = qualified_flag unless qualified_flag == :absent
    Setting.set('Company', company.id, 'pipeline_stages', [
      { 'key' => 'lead', 'name' => 'Lead', 'order' => 0 }, qualified,
      { 'key' => 'won', 'name' => 'Won', 'order' => 2 }, { 'key' => 'lost', 'name' => 'Lost', 'order' => 3 }
    ])
  end

  it 'lands in the first stage when no stage carries a flag' do
    stages
    expect(company.default_deal_stage).to eq('lead')
  end

  it 'still lands in the first stage when a later one is switched on' do
    stages(qualified_flag: true)
    expect(company.default_deal_stage).to eq('lead')
  end

  it 'skips a stage that is switched off' do
    Setting.set('Company', company.id, 'pipeline_stages', [
      { 'key' => 'lead', 'name' => 'Lead', 'order' => 0, 'active' => false },
      { 'key' => 'qualified', 'name' => 'Qualified', 'order' => 1 }
    ])
    expect(company.default_deal_stage).to eq('qualified')
  end
end
