# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::PriceBooks::OptionReview do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2027', status: 'published') }
  let(:kitchen) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen & Appliances', position: 7) }
  let(:frame) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'frame', name: 'Frame & Transport', position: 3) }

  def option(group, name, standard: false)
    CatalogOption.create!(group: group, manufacturer: mfr, key: "#{group.key}--#{name.parameterize}", name: name, kind: 'upgrade').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, is_standard: standard, dealer_cost: 100)
    end
  end

  let!(:sxs) { option(kitchen, 'Side by Side Fridge Upgrade') }
  let!(:french) { option(kitchen, 'French Door Fridge Upgrade') }
  let!(:axle) { option(frame, 'Extra Axle') }

  it "records Claude's decisions for buyer options it has not decided, and skips them next time" do
    sent = nil
    allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |content:, **|
      sent = content.first[:text]
      { input: { 'families' => [{ 'family' => 'Refrigerator', 'ids' => [sxs.id, french.id], 'reason' => 'One fridge per kitchen.' }],
                 'includes' => [{ 'ids' => [axle.id], 'family' => 'refrigerator', 'reason' => 'not sent' }] },
        input_tokens: 4000, output_tokens: 300 }
    end
    summary = described_class.new(book).call

    expect(sent).to include("#{sxs.id} | Kitchen & Appliances | Side by Side Fridge Upgrade")
    expect(sent).not_to include('Extra Axle')
    rows = CatalogOptionDecision.where(manufacturer: mfr)
    expect(rows.pluck(:option_key, :kind, :value)).to contain_exactly([sxs.key, 'family', 'refrigerator'], [french.key, 'family', 'refrigerator'])
    expect(rows.pluck(:suggestion).uniq.size).to eq(1)
    expect(rows.first).to have_attributes(source: 'claude', status: 'active', note: 'One fridge per kitchen.', catalog_price_book_id: book.id)
    expect(summary).to include(suggestions: 2, options_sent: 2)
    expect(book.reload.metadata['option_review']).to include('suggestions' => 2)

    # Every option is decided now: nothing left to send.
    RSpec::Mocks.space.proxy_for(Catalog::PriceBooks::ClaudeClient).reset
    expect(Catalog::PriceBooks::ClaudeClient).not_to receive(:call)
    expect(described_class.new(book).call).to include(options_sent: 0)
  end

  # Production raised NameError here for every book with such an option.
  it 'tells Claude the family an option already falls in' do
    package = option(kitchen, 'Stainless Appliance Package')
    sent = nil
    allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |content:, **|
      sent = content.first[:text]
      { input: {}, input_tokens: 1, output_tokens: 1 }
    end
    described_class.new(book).call
    expect(sent).to include("#{package.id} | Kitchen & Appliances | Stainless Appliance Package | upgrade, family=appliance package")
  end

  it "teaches Claude the factory's reviewed decisions" do
    other = option(kitchen, 'Ice Maker Kit')
    CatalogOptionDecision.create!(manufacturer: mfr, option_key: other.key, kind: 'family', value: 'refrigerator', source: 'claude',
                                  status: 'rejected', reviewed_at: Time.current, note: 'An ice maker goes with any fridge.')
    sent = nil
    allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) do |content:, **|
      sent = content.first[:text]
      { input: {}, input_tokens: 1, output_tokens: 1 }
    end
    described_class.new(book).call
    expect(sent).to include('WRONG: family refrigerator for "Ice Maker Kit" (An ice maker goes with any fridge.)')
    expect(sent).not_to include("#{other.id} | ")
  end
end
