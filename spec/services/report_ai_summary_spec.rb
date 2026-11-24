# frozen_string_literal: true

require 'rails_helper'

# The one-line summary above an AI report must never state a total or average
# worked out from the five rows it can see of a longer list.
RSpec.describe ReportAiService, '#summarize_results' do
  let(:service) { described_class.allocate }
  let(:columns) { [{ key: 'name', label: 'Name' }, { key: 'sale_price', label: 'Sale Price' }] }

  def prompt_for(rows:, total:)
    sent = nil
    allow(service).to receive(:call_claude) do |prompt, **|
      sent = prompt
      { 'content' => [{ 'text' => 'ok' }] }
    end
    service.summarize_results('average sale price', { columns: columns, rows: rows, meta: { total: total } })
    sent
  end

  it 'gives the true count and forbids a total when it cannot see every row' do
    rows = Array.new(50) { |i| { 'name' => "Deal #{i}", 'sale_price' => 1000 } }
    prompt = prompt_for(rows: rows, total: 3_000)
    expect(prompt).to include('matched 3000 records')
    expect(prompt).to include('do NOT work one out')
    expect(prompt).to include('Fields: Name, Sale Price.')
  end

  it 'lets it answer from the rows when it sees them all' do
    rows = [{ 'name' => 'A', 'sale_price' => 10 }, { 'name' => 'B', 'sale_price' => 20 }]
    prompt = prompt_for(rows: rows, total: 2)
    expect(prompt).to include('all shown here')
    expect(prompt).not_to include('do NOT work one out')
  end
end
