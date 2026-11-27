# frozen_string_literal: true

require 'rails_helper'
require 'csv'

# Report AI answers by groups with totals, says what a report could not
# cover (and hands that to support), and an answer can be exported or saved.
RSpec.describe 'Report AI grouped answers, export and save', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', company: company,
                 first_name: 'Ana', last_name: 'Rep', role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:buyer) { company.contacts.create!(first_name: 'Cy', last_name: 'Buyer') }
  let(:grouped_query) do
    { module: 'deals', fields: %w[owner_id selling_price], filters: {}, group_by: 'owner_id',
      aggregates: [{ fn: 'count' }, { fn: 'sum', field: 'selling_price' }], sort_by: 'sum_selling_price', sort_order: 'desc' }
  end

  before do
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', 5)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
    [100_000, 50_000].each do |price|
      company.deals.create!(name: "D #{price}", contact_id: buyer.id, owner_id: user.id, selling_price: price, stage: 'closed_won')
    end
  end

  def claude_returns(json)
    allow_any_instance_of(ReportAiService).to receive(:call_claude) do |_svc, _prompt, **opts|
      text = opts[:max_tokens] == 150 ? 'Ana Rep sold the most.' : json.to_json
      { 'content' => [{ 'text' => text }], 'usage' => { 'input_tokens' => 100, 'output_tokens' => 50 } }
    end
  end

  it 'answers with groups, totals and a chart' do
    claude_returns(module_key: 'deals', fields: %w[owner_id selling_price], filters: {}, group_by: 'owner_id',
                   aggregates: [{ fn: 'count' }, { fn: 'sum', field: 'selling_price' }], chart: { type: 'bar' },
                   fully_answered: true, explanation: 'Sales by salesperson.')
    post '/api/v1/report-ai/ask', params: { question: 'total sales by salesperson' }, headers: headers
    body = response.parsed_body
    expect(body.dig('data', 'rows')).to eq([{ 'owner_id' => 'Ana Rep', 'count' => 2, 'sum_selling_price' => 150_000.0 }])
    expect(body['chart']).to eq('type' => 'bar')
    expect(body['fully_answered']).to be(true)
  end

  it 'says what it could not cover and hands it to support' do
    claude_returns(module_key: 'deals', fields: %w[owner_id selling_price], filters: {}, group_by: 'owner_id',
                   aggregates: [{ fn: 'count' }], fully_answered: false,
                   not_covered: 'Reports cannot work out margin percent.', explanation: 'Deals by salesperson.')
    expect { post '/api/v1/report-ai/ask', params: { question: 'margin percent by rep' }, headers: headers }
      .to change { GuideFlag.where(kind: 'not_expressible', source: 'report_ai').count }.by(1)
    expect(response.parsed_body['not_covered']).to eq('Reports cannot work out margin percent.')
    expect(GuideFlag.last.assistant_reason).to eq('Reports cannot work out margin percent.')
  end

  it 'falls back to the list when the AI asks for a grouping the report does not have' do
    claude_returns(module_key: 'deals', fields: %w[name selling_price], filters: {}, group_by: 'made_up_field',
                   fully_answered: true, explanation: 'Deals.')
    post '/api/v1/report-ai/ask', params: { question: 'deals by colour' }, headers: headers
    body = response.parsed_body
    expect(response).to have_http_status(:ok)
    expect(body['fully_answered']).to be(false)
    expect(body['not_covered']).to include('could not be grouped')
    expect(body.dig('data', 'rows').size).to eq(2)
  end

  it 'exports an answer as a recorded CSV' do
    expect { post '/api/v1/report-ai/export', params: { query: grouped_query, name: 'Sales by rep' }, headers: headers, as: :json }
      .to change(ExportJob, :count).by(1)
    rows = CSV.parse(response.body)
    expect(rows[0]).to eq(['Assigned To', 'Count', 'Total Selling Price', 'export_ref'])
    expect(rows[1][0..2]).to eq(['Ana Rep', '2', '150000.0'])
    expect(response.headers['X-Export-Total']).to eq('1')
  end

  it 'saves an answer as a private report that runs again grouped' do
    post '/api/v1/report-ai/save', params: { query: grouped_query, name: 'Sales by rep', chart: { type: 'bar' } }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    report = company.reports.find(response.parsed_body.dig('report', 'id'))
    expect(report).to have_attributes(visibility: 'private', module_key: 'deals', user_id: user.id)
    expect(report.config).to include('group_by' => 'owner_id', 'chart' => { 'type' => 'bar' })

    get "/api/v1/reports/#{report.id}/export", headers: headers
    expect(CSV.parse(response.body)[1][0]).to eq('Ana Rep')
  end

  it 'refuses a module the person cannot read' do
    post '/api/v1/report-ai/export', params: { query: { module: 'nope' } }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
