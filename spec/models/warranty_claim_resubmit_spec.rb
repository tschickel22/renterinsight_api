# frozen_string_literal: true

require 'rails_helper'

# ServiceTicket#resync_draft_claim! is draft-only on purpose, so a submitted
# claim stays frozen at whatever the manufacturer received. That left no way to
# get later ticket edits to the manufacturer at all: resubmitting re-sent the
# identical figures. Claims imported straight to "submitted" never carried line
# items, so they resent $0.00 however the ticket was tagged.
RSpec.describe WarrantyClaim, '#resubmit!' do
  let(:labor_lines) do
    [
      { 'description' => 'Drive time',  'hours' => 3,   'rate' => 25 },
      { 'description' => 'milage',      'hours' => 150, 'rate' => 0.95 },
      { 'description' => 'Labor hours', 'hours' => 4,   'rate' => 65 }
    ]
  end

  let(:claim) { described_class.new(status: 'submitted') }
  let(:captured) { {} }

  before do
    allow(claim).to receive(:send_manufacturer_notification)
    allow(claim).to receive(:update!) { |attrs| captured.merge!(attrs) }
    allow(claim).to receive(:service_ticket).and_return(ticket)
  end

  context 'when the ticket has warranty-tagged lines' do
    let(:ticket) do
      instance_double(
        ServiceTicket,
        has_warranty_items?: true,
        warranty_parts: [],
        warranty_labor: labor_lines,
        warranty_total: 477.5
      )
    end

    it 'refreshes the claim from the ticket instead of resending stale figures' do
      claim.resubmit!('Tom')

      expect(captured[:estimated_amount]).to eq(477.5)
      expect(captured[:labor]).to eq(labor_lines)
      expect(captured[:parts]).to eq([])
    end

    it 'still performs the resubmission itself' do
      expect(claim).to receive(:send_manufacturer_notification)

      expect(claim.resubmit!('Tom')).to be true
      expect(captured[:status]).to eq('resubmitted')
      expect(captured[:submitted_by]).to eq('Tom')
    end
  end

  context 'when the ticket has no warranty-tagged lines' do
    let(:ticket) { instance_double(ServiceTicket, has_warranty_items?: false) }

    it 'leaves existing line items alone rather than zeroing the claim' do
      claim.resubmit!('Tom')

      expect(captured).not_to have_key(:labor)
      expect(captured).not_to have_key(:parts)
      expect(captured).not_to have_key(:estimated_amount)
      expect(captured[:status]).to eq('resubmitted')
    end
  end

  context 'when the claim cannot be resubmitted' do
    let(:ticket) { instance_double(ServiceTicket) }

    it 'refuses a draft claim' do
      claim.status = 'draft'
      expect(claim.resubmit!('Tom')).to be false
      expect(captured).to be_empty
    end

    it 'refuses a closed claim' do
      claim.status = 'closed'
      expect(claim.resubmit!('Tom')).to be false
      expect(captured).to be_empty
    end
  end
end
