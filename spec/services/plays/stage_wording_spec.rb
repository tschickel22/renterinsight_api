# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Play stage wording' do
  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }

  it 'says whose reply the play is waiting on' do
    labels = Plays::Tracking.stage_labels(company)

    expect(labels['waiting_for_reply']).to eq('Waiting for the lead to reply')
    expect(labels['replied']).to eq('Replied')

    columns = Plays::Board.new(company: company).call[:columns].to_h { |c| [c[:key], c[:label]] }
    expect(columns['waiting']).to eq('Waiting for the lead to reply')
    # A reply stops the play, so the next move is the rep's.
    expect(columns['talking']).to eq('Replied, needs response')
  end

  it "uses the dealer's own word for a lead" do
    Setting.set('Company', company.id, 'label_overrides', { 'lead' => 'Guest' })

    expect(Plays::Tracking.stage_labels(company.reload)['waiting_for_reply']).to eq('Waiting for the guest to reply')
    expect(Plays::Board.new(company: company.reload).call[:columns].find { |c| c[:key] == 'waiting' }[:label])
      .to eq('Waiting for the guest to reply')
  end
end
