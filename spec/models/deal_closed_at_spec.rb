# frozen_string_literal: true

require 'rails_helper'

# A deal moved to won or lost any way records when (dashboards count won
# deals by won_at; deals closed through Edit Deal or the board had none).
RSpec.describe Deal, 'closed dates' do
  let(:company) { create(:company) }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:account) { company.accounts.create!(name: 'Buyer') }

  it 'stamps won_at and the close date on a stage change to won, and lost_at on lost' do
    deal = company.deals.create!(name: 'D', location: location, account: account, stage: 'negotiation')
    deal.update!(stage: 'closed_won')
    expect(deal.reload.won_at).to be_present
    expect(deal.actual_close_date).to eq(Date.current)

    lost = company.deals.create!(name: 'L', location: location, account: account, stage: 'proposal')
    lost.update!(stage: 'closed_lost')
    expect(lost.reload.lost_at).to be_present
  end

  it 'keeps a won_at already set' do
    at = 3.days.ago.change(usec: 0)
    deal = company.deals.create!(name: 'D', location: location, account: account, stage: 'negotiation')
    deal.update!(stage: 'closed_won', won_at: at)
    expect(deal.reload.won_at).to eq(at)
  end
end
