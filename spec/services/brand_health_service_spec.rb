# frozen_string_literal: true

require 'rails_helper'

# Regression: Meta rejects the whole insights call if a single metric name is
# unknown, so the deprecated page_engaged_users / page_views_total silently
# zeroed the entire brand-health dashboard rather than dropping two figures.
RSpec.describe BrandHealthService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let!(:integration) do
    company.facebook_integrations.create!(page_id: 'page-1', page_name: 'DealerTide',
                                          page_access_token: 'PAGE-TOKEN', status: 'active',
                                          is_deleted: false)
  end

  let(:page_data) { { 'id' => 'page-1', 'name' => 'DealerTide', 'fan_count' => 10 } }

  def stub_graph(insights:)
    allow(MetaGraphApi).to receive(:get) do |path, _token, **params|
      if path == '/page-1' then page_data
      elsif path.end_with?('/insights') then insights.call(params[:metric])
      else { 'data' => [] }
      end
    end
  end

  it 'does not request metrics Meta removed in the 2024 cull' do
    expect(described_class::METRICS).not_to include('page_engaged_users', 'page_views_total')
  end

  it 'asks for the current engagement metric' do
    expect(described_class::METRICS).to include('page_post_engagements')
  end

  it 'passes the metric list through on success' do
    seen = nil
    stub_graph(insights: ->(metric) { seen = metric; { 'data' => [] } })

    described_class.fetch_for_company(company)

    expect(seen).to eq(described_class::METRICS.join(','))
  end

  # Metric deprecation is continuous — one unknown name shouldn't cost the
  # whole dashboard, so a rejected batch retries with the stable subset.
  it 'retries with the fallback metrics when the batch is rejected' do
    attempts = []
    stub_graph(insights: lambda { |metric|
      attempts << metric
      raise MetaGraphApi::Error, '(#100) The value must be a valid insights metric' if attempts.size == 1

      { 'data' => [{ 'name' => 'page_fans', 'values' => [{ 'value' => 10 }] }] }
    })

    result = described_class.fetch_for_company(company)

    expect(attempts.length).to eq(2)
    expect(attempts.last).to eq(described_class::FALLBACK_METRICS.join(','))
    expect(result).not_to be_nil
  end

  it 'still returns page data when insights fail entirely' do
    stub_graph(insights: ->(_m) { raise MetaGraphApi::Error, 'nope' })

    result = described_class.fetch_for_company(company)

    expect(result).not_to be_nil
    expect(result[:page][:name]).to eq('DealerTide')
  end
end
