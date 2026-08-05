# frozen_string_literal: true

require 'rails_helper'

# Every block in SearchController#global and #related is wrapped in its own
# `begin/rescue => e; Rails.logger.error(...)`. A broken query in one block
# doesn't raise — it silently drops that whole result type from the response,
# which is exactly the kind of failure that reaches production unnoticed.
#
# So: hit the real endpoints, and fail the example if ANY block logged.
RSpec.describe 'Api::V1::Search', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com",
                 first_name: 'T', last_name: 'U', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'X-Company-ID' => company.id.to_s } }

  let!(:lead) do
    FactoryBot.create(:lead, company: company, first_name: 'Don', last_name: 'Killins',
                             email: 'dee@donkillins.com', company_name: 'Country Village')
  end
  let!(:contact) do
    company.contacts.create!(first_name: 'Don', last_name: 'Killins', email: 'dee@donkillins.com')
  end

  # Captures the swallowed-exception log lines the rescue blocks emit.
  def swallowed_errors
    lines = []
    allow(Rails.logger).to receive(:error) { |msg| lines << msg.to_s }
    yield
    lines.grep(/error:/)
  end

  def results_for(path, params)
    logged = swallowed_errors { get path, params: params, headers: auth_headers }
    expect(response).to have_http_status(:ok)
    expect(logged).to be_empty, "search blocks failed silently:\n#{logged.join("\n")}"
    JSON.parse(response.body)['results']
  end

  describe 'GET /api/v1/search/global' do
    it 'finds the lead and the contact by full name, with no block failing silently' do
      results = results_for('/api/v1/search/global', { query: 'don kill' })

      expect(results.map { |r| r['type'] }).to include('lead', 'contact')
      expect(results.map { |r| r['title'] }).to all(eq('Don Killins'))
    end

    it 'runs every block clean for a query that matches nothing' do
      expect(results_for('/api/v1/search/global', { query: 'zzzz nomatch' })).to be_empty
    end

    it 'finds the lead by first name alone' do
      results = results_for('/api/v1/search/global', { query: 'don' })

      expect(results.select { |r| r['type'] == 'lead' }.map { |r| r['id'] }).to include(lead.id)
    end

    it 'finds the lead by email' do
      results = results_for('/api/v1/search/global', { query: 'dee@donkillins.com' })

      expect(results.select { |r| r['type'] == 'lead' }.map { |r| r['id'] }).to include(lead.id)
    end

    it 'does not treat a wildcard query as "match everything"' do
      expect(results_for('/api/v1/search/global', { query: '%%' })).to be_empty
    end
  end

  describe 'GET /api/v1/search/related' do
    it 'finds the contact and lead by full name, with no block failing silently' do
      results = results_for('/api/v1/search/related', { query: 'don kill' })

      expect(results.map { |r| r['type'] }).to include('contact', 'lead')
    end

    it 'runs every block clean for a query that matches nothing' do
      expect(results_for('/api/v1/search/related', { query: 'zzzz nomatch' })).to be_empty
    end
  end
end
