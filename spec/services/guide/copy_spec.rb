# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Guide::Copy do
  let(:company) { create(:company) }

  it "fills in the brand and the dealer's own words, falling back to the default" do
    allow(company).to receive(:resolved_labels).and_return('leads' => 'Prospects')
    text = 'Open {{label:leads|Prospecting}} in {{brand}}, then {{label:deals|Sales Deals}}.'

    expect(described_class.render(text, company: company))
      .to eq("Open Prospects in #{Brand.current(company: company).name}, then Sales Deals.")
    expect(described_class.render(text)).to start_with('Open Prospecting in ')
  end

  it 'fills in every string in an Atlas entry' do
    entry = { 'title' => '{{label:leads|Prospecting}}', 'where' => [{ 'text' => 'Click {{label:leads|Prospecting}}.' }], 'n' => 1 }
    expect(described_class.render_deep(entry)).to eq('title' => 'Prospecting', 'where' => [{ 'text' => 'Click Prospecting.' }], 'n' => 1)
  end
end
