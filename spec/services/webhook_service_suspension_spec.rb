# frozen_string_literal: true

require 'rails_helper'

# A webhook carries a company's records to a third-party URL, so a suspended
# tenant with a live endpoint would keep data flowing out of an account that is
# shut off everywhere a person or an API key can reach it.
RSpec.describe WebhookService, '.fire under a suspended company' do
  let(:company) { create(:company, status: company_status) }
  let(:creator) do
    User.create!(
      email: "owner-#{SecureRandom.hex(4)}@example.com",
      first_name: 'Owner', company_id: company.id, status: 'active', password: 'secret123'
    )
  end

  let!(:endpoint) do
    WebhookEndpoint.create!(
      company: company,
      url: 'https://example.test/hook',
      secret: SecureRandom.hex(16),
      events: ['lead.created'],
      status: 'active',
      created_by_user_id: creator.id
    )
  end

  def fire!
    described_class.fire(company_id: company.id, event: 'lead.created', payload: { id: 1 })
  end

  context 'when the company is active' do
    let(:company_status) { 'active' }

    it 'delivers' do
      expect { fire! }.to change(WebhookDelivery, :count).by(1)
    end
  end

  %w[suspended cancelled].each do |status|
    context "when the company is #{status}" do
      let(:company_status) { status }

      # Dropped rather than queued: a hold can last months, and replaying a
      # backlog of stale events at whoever is on the other end when the account
      # returns is worse than the gap.
      it 'delivers nothing' do
        expect { fire! }.not_to change(WebhookDelivery, :count)
      end

      # The property that matters for a billing hold: one flag, no second piece
      # of state to remember, and the endpoint never touched.
      it 'resumes the moment the company is active again' do
        expect { fire! }.not_to change(WebhookDelivery, :count)

        company.update!(status: 'active')

        expect { fire! }.to change(WebhookDelivery, :count).by(1)
        expect(endpoint.reload.status).to eq('active')
      end
    end
  end
end
