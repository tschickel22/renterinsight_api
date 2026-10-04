# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::NewHomes do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026', status: 'published') }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, series: 'Aspire', name: 'Belvidere', slug: "b-#{SecureRandom.hex(2)}") }
  let(:priced) do
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56)
                      .tap { |v| CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 90_000) }
  end
  let(:dealer) { Company.create!(name: "Summit #{SecureRandom.hex(2)}") }
  let!(:admin) { User.create!(email: "pa#{SecureRandom.hex(3)}@example.com", password: 'Passw0rd!x', role: 'platform_admin', company: dealer) }

  def home(**attrs)
    dealer.vehicles.create!({ make: 'Champion', model: 'Belvidere', year: 2026, bedrooms: 3, bathrooms: 2, serial_number: SecureRandom.hex(4),
                              listing_type: 'manufactured_home', source: 'champion_ims' }.merge(attrs))
  end

  it 'leads with what needs doing: an undrawn priced model, an unpriced one, a home no model matched' do
    home(catalog_plan_variant_id: priced.id)
    home(model: 'Mystery 1676', catalog_plan_variant_id: nil, source: 'catalog_import')
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '1676H11111', width_ft: 16, length_ft: 76)
    home(source: 'champion_ims_clone') # a dealer's own copy, not a feed arrival

    expect { described_class.digest! }.to change { Notification.where(recipient: admin, notification_type: 'new_homes_digest').count }.by(1)
    note = Notification.where(recipient: admin).last
    expect(note.title).to eq('2 new homes and 2 new models from the feeds')
    expect(note.message).to include('1 from the Champion feed', '1 from the factory sites',
                                    'Needs a factory run (priced, no drawings): ', '2856H32392',
                                    'No factory prices yet', '1676H11111', 'Not matched to any model: Champion Mystery 1676')
    expect(note.message).not_to match(/[–—]/)
  end

  it 'counts only what arrived since the last digest, and stays quiet when nothing did' do
    home(catalog_plan_variant_id: priced.id)
    described_class.digest!
    expect { described_class.digest! }.not_to(change { Notification.count })
    expect(described_class.last_digest_at).to be_within(5.seconds).of(Time.current)
  end
end
