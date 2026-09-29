# frozen_string_literal: true

require 'rails_helper'

# The settings page polls this status while an import runs.
RSpec.describe FacebookLeadImportJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let!(:integration) do
    FacebookIntegration.create!(company: company, page_id: 'page-1', page_name: 'Summit Park Homes',
                                page_access_token: 'token', status: 'active')
  end

  it 'records the finished counts' do
    allow(MetaGraphApi).to receive(:each_lead_form).and_yield({ 'id' => 'form-a', 'name' => 'Spring' })
    allow(MetaGraphApi).to receive(:each_form_lead)

    described_class.perform_now(integration.id, dry_run: true)

    status = described_class.status_for(integration)
    expect(status).to include('state' => 'finished', 'dry_run' => true)
    expect(status['progress']).to include('forms' => 1, 'found' => 0)
  end

  it 'marks the connection expired and says what to do when the token is dead' do
    allow(MetaGraphApi).to receive(:each_lead_form).and_raise(MetaGraphApi::ExpiredTokenError, 'Session has expired')

    described_class.perform_now(integration.id, dry_run: true)

    expect(described_class.status_for(integration)).to include('state' => 'failed')
    expect(described_class.status_for(integration)['error']).to include('Reconnect the Page')
    expect(integration.reload.status).to eq('expired')
  end
end
