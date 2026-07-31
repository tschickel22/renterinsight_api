# frozen_string_literal: true

require 'rails_helper'

# Submission gated on parts alone while telling the dealer that labor counted
# too. Labor-only warranty work is ordinary (drive time, mileage, hours with no
# parts consumed), so those claims could never be sent and the stated reason was
# wrong. The gate still has to refuse genuinely empty claims: this tenant has
# hundreds of imported ones carrying no line items at all, and none of them
# should ever reach a manufacturer.
RSpec.describe WarrantyClaim, 'submission gating' do
  let(:labor_lines) do
    [{ 'description' => 'Drive time', 'hours' => 3, 'rate' => 25, 'total' => 75 }]
  end
  let(:parts_lines) do
    [{ 'description' => 'Door seal', 'quantity' => 1, 'unit_price' => 40, 'total' => 40 }]
  end

  def claim_with(parts:, labor:, status: 'draft', manufacturer_id: 35)
    claim = described_class.new(status: status, manufacturer_id: manufacturer_id, parts: parts, labor: labor)
    allow(claim).to receive(:manufacturer_claim_email).and_return('factory@example.com')
    claim
  end

  it 'accepts a labor-only claim' do
    claim = claim_with(parts: [], labor: labor_lines)

    expect(claim.line_items?).to be true
    expect(claim.can_be_submitted?).to be true
    expect(claim.submission_blocked_reason).to be_nil
  end

  it 'accepts a parts-only claim' do
    expect(claim_with(parts: parts_lines, labor: []).can_be_submitted?).to be true
  end

  it 'accepts a claim carrying both' do
    expect(claim_with(parts: parts_lines, labor: labor_lines).can_be_submitted?).to be true
  end

  it 'still refuses a claim with nothing billable' do
    claim = claim_with(parts: [], labor: [])

    expect(claim.line_items?).to be false
    expect(claim.can_be_submitted?).to be false
    expect(claim.submission_blocked_reason).to match(/parts or labor/)
  end

  it 'refuses a claim that is not a draft' do
    claim = claim_with(parts: [], labor: labor_lines, status: 'submitted')

    expect(claim.submission_blocked_reason).to eq('Already submitted')
  end

  it 'refuses a claim with no manufacturer' do
    claim = claim_with(parts: [], labor: labor_lines, manufacturer_id: nil)

    expect(claim.submission_blocked_reason).to eq('No manufacturer selected')
  end

  it 'refuses when the manufacturer has no claim email, so nothing is sent nowhere' do
    claim = described_class.new(status: 'draft', manufacturer_id: 35, parts: [], labor: labor_lines)
    allow(claim).to receive(:manufacturer_claim_email).and_return(nil)

    expect(claim.can_be_submitted?).to be false
    expect(claim.submission_blocked_reason).to match(/no claim email/)
  end
end
