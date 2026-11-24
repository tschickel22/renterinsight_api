# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# The help assistant reads records through the Claude connector's read tools,
# as the person asking (E118). It must never be able to change anything.
RSpec.describe Guide::LookUp do
  include McpConnectorHelpers

  it 'offers only read-only tools, never a write tool' do
    names = described_class.tools.keys
    write_names = McpController::WRITE_TOOLS.map(&:name_value)
    expect(names).not_to be_empty
    expect(names & write_names).to be_empty
    described_class.tools.each_value do |tool|
      expect(tool.write_tool?).to be(false)
      expect(tool.annotations_value.read_only_hint).to be(true)
    end
  end

  context 'calling a tool' do
    before { seed_rbac! }

    let(:company) { connector_company }

    it 'reads with the person\'s own permissions' do
      user = connector_user(company, { 'deals' => %w[read] })
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('list_leads', {})
      expect(out[:not_allowed] || out['not_allowed']).to be_present
    end

    it 'returns records the person can read' do
      user = connector_user(company, { 'leads' => %w[read] })
      company.leads.create!(first_name: 'Pat', last_name: 'Buyer', email: 'pat@example.com')
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('list_leads', { 'limit' => 5 })
      expect(out.to_json).to include('Pat')
    end

    it 'refuses a tool that is not on the list' do
      user = connector_user(company, { 'leads' => %w[read update] })
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('update_lead_status', {})
      expect(out[:error]).to include('No lookup called')
    end

    it 'stops at the per question row budget' do
      user = connector_user(company, { 'leads' => %w[read] })
      ctx = Guide::AppContext.new(user: user, company: company)
      ctx.used!(Guide::AppContext::ROWS_PER_QUESTION)
      out = described_class.new(ctx).call('list_leads', {})
      expect(out[:not_allowed]).to include('as many records as I can read')
    end
  end

  it 'keeps a large result under the size limit by dropping items' do
    big = { leads: Array.new(400) { |i| { id: "lead:#{i}", name: "Person number #{i}", note: 'x' * 40 } } }
    fitted = Guide::Fit.call(big, max_chars: 4_000)
    expect(fitted.to_json.length).to be <= 4_000
    expect(fitted[:leads_left_out]).to be > 0
    expect(JSON.parse(fitted.to_json)).to be_a(Hash)
  end
end
