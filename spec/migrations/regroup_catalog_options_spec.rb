# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260930140000_regroup_catalog_options')

RSpec.describe RegroupCatalogOptions do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026') }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, series: 'Aspire', name: 'Baldwin') }

  def group(name) = CatalogOptionGroup.create!(manufacturer: mfr, key: name.parameterize, name: name)

  def option(grp, name)
    opt = CatalogOption.create!(group: grp, manufacturer: mfr, key: "#{grp.key}--#{name.parameterize}", name: name)
    CatalogOptionPrice.create!(price_book: book, option: opt, dealer_cost: 100)
    opt
  end

  it 'moves options onto the canonical groups, merges continuations, and ties model sections to their model' do
    cabinets = group('Cabinets')
    cont = group('Cabinets Cont.')
    baldwin = group('(Baldwin)   2876 H42180 Swayzee')
    kept = option(cabinets, 'Cabinet Knobs')
    dupe = option(cont, 'Cabinet Knobs')
    island = option(cont, 'Ultimate Island')
    porch = option(baldwin, 'Covered Porch')
    variant = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2876H42180')

    described_class.new.up

    target = CatalogOptionGroup.find_by!(manufacturer: mfr, key: 'cabinets')
    expect(kept.reload).to have_attributes(catalog_option_group_id: target.id, key: 'cabinets--cabinet-knobs')
    expect(CatalogOption.exists?(dupe.id)).to be(false)
    expect(kept.prices.count).to eq(2)
    expect(island.reload.group).to eq(target)
    expect(CatalogOptionGroup.exists?(cont.id)).to be(false)

    expect(porch.reload.group.key).to eq('floor-plan')
    expect(porch.prices.first.catalog_plan_variant_id).to eq(variant.id)
    expect(CatalogOptionGroup.where(manufacturer: mfr).pluck(:key)).to contain_exactly('cabinets', 'floor-plan')
  end
end
