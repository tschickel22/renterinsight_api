# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::DegradationAlerter do
  let!(:admin) do
    company = Company.create!(name: "Alert-#{SecureRandom.hex(3)}")
    User.create!(email: "pa-#{SecureRandom.hex(3)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def source(name:, adapter: 'tru_model_line')
    CatalogSource.create!(name: "#{name}-#{SecureRandom.hex(3)}", adapter_type: adapter,
                          base_url: "https://example.test/#{SecureRandom.hex(3)}",
                          enabled: true, extraction_threshold: 0.7)
  end

  def run_for(src, rates, errors: [], degraded: true)
    ScrapeRun.create!(catalog_source_id: src.id, status: 'partial', degraded: degraded,
                      started_at: 1.hour.ago, finished_at: 1.hour.ago,
                      field_extraction_rates: rates, error_log: errors)
  end

  def last_notification = Notification.order(:created_at).last

  describe 'a drop the manufacturer caused' do
    let(:mini) { source(name: 'Tru Mini') }
    let!(:healthy_sibling) { run_for(source(name: 'Tru Homes'), { 'images' => 0.9231 }, degraded: false) }
    let(:run) do
      run_for(mini, { 'images' => 0.0 },
              errors: [{ 'url' => 'https://owntru.com/models/trt12361ph/', 'field' => 'images',
                         'message' => 'failed smoke check' }])
    end

    it 'leads with the fact that there is nothing to do' do
      described_class.call(source: mini, run: run)

      expect(last_notification.message).to match(/\ANothing to fix here/)
    end

    # system_alert is urgent by default, which is right for a broken scraper and
    # wrong for a manufacturer publishing a page without photos. An alert that
    # cannot be acted on should not read like one, or the ones that can stop
    # being read.
    it 'does not shout' do
      described_class.call(source: mini, run: run)

      expect(last_notification.priority).to eq('normal')
    end

    # So chasing it does not start with working out which pages they were.
    it 'names the pages to send the manufacturer' do
      described_class.call(source: mini, run: run)

      expect(last_notification.message).to include('https://owntru.com/models/trt12361ph/')
    end

    it 'still says what dropped and that nothing was overwritten' do
      described_class.call(source: mini, run: run)

      expect(last_notification.message).to include('images 0% (threshold 70%)')
      expect(last_notification.message).to include('preserved')
    end
  end

  describe 'a drop that looks like ours' do
    let(:mini) { source(name: 'Tru Mini') }
    let!(:broken_sibling) { run_for(source(name: 'Tru Homes'), { 'images' => 0.0 }) }
    let(:run) { run_for(mini, { 'images' => 0.0 }) }

    it 'keeps the urgency' do
      described_class.call(source: mini, run: run)

      expect(last_notification.priority).to eq('urgent')
      expect(last_notification.message).to match(/worth looking at/i)
    end
  end

  # A diagnosis is a courtesy on top of the alert. Losing it must not lose the
  # alert, which is the thing that says data stopped arriving.
  it 'still alerts when the diagnosis blows up' do
    mini = source(name: 'Tru Mini')
    run = run_for(mini, { 'images' => 0.0 })
    allow(Catalog::DegradationDiagnosis).to receive(:call).and_raise(StandardError, 'boom')

    expect { described_class.call(source: mini, run: run) }
      .to change { Notification.count }.by(1)
    expect(last_notification.message).to include('images 0%')
  end
end
