# frozen_string_literal: true

require 'rails_helper'

# Park models (ANSI A119.5, e.g. Cavco Ocala's Eagle line) are priced in books
# as their own build, never labelled HUD.
RSpec.describe 'Park model (ANSI) homes in TrueBuild' do
  let(:mfr) { Manufacturer.create!(name: "Mfr #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Ocala', code: "O#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Eagle', name: 'Eagle') }
  let(:park) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '11351B', width_ft: 11, length_ft: 35, building_code: 'ANSI') }
  let(:hud) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '13381C', width_ft: 13, length_ft: 38, building_code: 'HUD') }
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }

  it 'saves a park model build' do
    expect(park).to be_persisted
    expect(CatalogPlanVariant.new(catalog_plan: plan, manufacturer: mfr, model_number: 'X1', building_code: 'RV')).not_to be_valid
  end

  it 'gives a park model surcharge rule to park models only' do
    rule = company.dealer_surcharge_rules.create!(manufacturer: mfr, building_code: 'ANSI', section: 'any', basis: 'flat', amount: 500)
    expect(DealerSurchargeRule.best_for([rule], park, factory.id)).to eq(rule)
    expect(DealerSurchargeRule.best_for([rule], hud, factory.id)).to be_nil
  end

  it 'reads a lot home marked park model as that build' do
    vehicle = Vehicle.new(building_code: 'ANSI')
    expect(Truebuild::HomeMatcher.new.send(:building_code, vehicle)).to eq('ANSI')
    expect(Truebuild::HomeMatcher.new.send(:building_code, Vehicle.new(building_code: 'HUD_MOD'))).to be_nil
  end
end
