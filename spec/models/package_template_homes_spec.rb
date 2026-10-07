# frozen_string_literal: true

require 'rails_helper'

# Quotes, invoices and Edit Deal saved every typed line as a template, the
# home line included, so homes showed up as add-ons ("2023 Cavco Crest
# $61,561"). A home is inventory, never a template.
RSpec.describe PackageTemplate do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def template(name, price, description = nil)
    described_class.new(company: company, name: name, default_price: price, description: description)
  end

  it 'leaves homes out of every list, and keeps the real add-ons' do
    keep = [template('Fencing', 500), template('Install & Delivery', 25_000), template('2024 Sales Event Fee', 295)]
    keep.each(&:save!)
    homes = [template('2023 Cavco Crest', 61_561), template('Show home', 90_000, 'VIN: 2860M32047'),
             template('Lot 12', 40_000, 'Corner lot [category:land]')]
    homes.each { |h| h.save!(validate: false) } # as the old forms created them

    expect(company.package_templates.not_homes.pluck(:name)).to match_array(keep.map(&:name))
  end

  it 'lists templates alphabetically' do
    %w[Skirting awning Fencing].each { |n| template(n, 100).save! }
    expect(company.package_templates.ordered.pluck(:name)).to eq(%w[awning Fencing Skirting])
  end

  it 'refuses to save a home as a template' do
    t = template('2026 Dutch Housing Verona', 159_231)
    expect(t.save).to be(false)
    expect(t.errors.full_messages).to include('A home is inventory, not a template')
    expect(template('Skirting', 1800, 'Vinyl [category:accessory]').save).to be(true)
  end
end
