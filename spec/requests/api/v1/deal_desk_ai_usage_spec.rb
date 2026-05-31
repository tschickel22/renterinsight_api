# frozen_string_literal: true

require 'rails_helper'

# Deal Desk AI shares the company's monthly AI budget (AiQueryLog), the same ledger and cap
# report_ai uses. Both LLM calls (interpret + narrate) are metered and tagged deal_desk_ai;
# over cap, the LLM is skipped but the engine still returns every figure.
RSpec.describe 'Api::V1 Deal Desk ai_solve usage tracking', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }
  let(:unit) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000, dealer_cost: 50_000,
                             location_id: location.id)
  end
  let(:deal) { company.deals.create!(name: 'Test Deal', account: account, vehicle: unit, location_id: location.id) }

  let(:interpret_body) do
    { 'usage' => { 'input_tokens' => 120, 'output_tokens' => 40 },
      'content' => [{ 'text' => '{"target_payment":650,"levers":["term"],"compare_units":false,"include_other_locations":false}' }] }
  end
  let(:narrate_body) do
    { 'usage' => { 'input_tokens' => 200, 'output_tokens' => 80 },
      'content' => [{ 'text' => '{"summary":"Extend the term to hit $650.","explanations":["term option"]}' }] }
  end

  before do
    # Ensure the platform key is present so the LLM path is enabled.
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
  end

  def ai_solve(body = { deal_id: deal.id, prompt: 'get them to $650/mo' })
    post '/api/v1/deal_desk/scenarios/ai_solve', params: body.to_json, headers: headers
    JSON.parse(response.body)
  end

  describe 'metering both LLM calls' do
    before do
      allow_any_instance_of(DealDesk::AiSolveService)
        .to receive(:post_to_anthropic).and_return(interpret_body, narrate_body)
    end

    it 'records one deal_desk_ai row per LLM call (interpret + narrate), tagged + with tokens' do
      expect { ai_solve }.to change { AiQueryLog.where(company: company, feature: 'deal_desk_ai', execution_status: 'success').count }.by(2)

      rows = AiQueryLog.where(company: company, feature: 'deal_desk_ai', execution_status: 'success')
      expect(rows.pluck(:action_name)).to match_array(%w[deal_desk_ai_interpret deal_desk_ai_narrate])
      expect(rows.sum(:input_tokens)).to eq(320)   # 120 + 200
      expect(rows.sum(:output_tokens)).to eq(120)  # 40 + 80
      expect(rows.where(action_name: 'deal_desk_ai_narrate').first.cost_cents).to be > 0
    end

    it 'returns the LLM summary alongside engine-computed options' do
      body = ai_solve
      expect(response).to have_http_status(:ok)
      expect(body['summary']).to eq('Extend the term to hit $650.')
      expect(body['options']).to be_present
    end
  end

  describe 'over cap' do
    before { allow(AiQueryLog).to receive(:over_cap?).and_return(true) }

    it 'skips the LLM entirely but still returns engine numbers' do
      expect_any_instance_of(DealDesk::AiSolveService).not_to receive(:post_to_anthropic)

      body = ai_solve
      expect(response).to have_http_status(:ok)
      expect(body['summary']).to be_nil
      expect(body['options']).to be_present
      expect(body['options'].first['monthly_payment'].to_f).to be > 0 # engine still computed
    end

    it 'logs a rate_limited row (no success rows)' do
      expect { ai_solve }.to change { AiQueryLog.where(company: company, feature: 'deal_desk_ai', execution_status: 'rate_limited').count }.by(1)
      expect(AiQueryLog.where(company: company, feature: 'deal_desk_ai', execution_status: 'success').count).to eq(0)
    end
  end
end
