# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DemoClock do
  let(:demo) { Company.create!(name: "Booth #{SecureRandom.hex(3)}", industry: 'manufactured_housing', is_demo: true) }
  let(:dealer) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }

  it 'runs days as minutes on a demo company once the clock is on' do
    expect(described_class.scale(demo, 1.day)).to eq(1.day)

    described_class.enable!(demo, true)

    expect(described_class.enabled?(demo)).to be true
    expect(described_class.scale(demo, 1.day)).to eq(60.seconds)
    expect(described_class.scale(demo, 24.hours)).to eq(60.seconds)
    expect(described_class.scale(demo, 1.hour)).to eq(5.seconds)

    described_class.enable!(demo, false)
    expect(described_class.scale(demo, 1.day)).to eq(1.day)
  end

  it 'never speeds up a company that is not a demo' do
    expect { described_class.enable!(dealer, true) }.to raise_error(ArgumentError, /demo companies/)

    Setting.set('Company', dealer.id, 'demo_clock', { 'enabled' => true })
    expect(described_class.enabled?(dealer)).to be false
    expect(described_class.scale(dealer, 1.day)).to eq(1.day)
  end
end
