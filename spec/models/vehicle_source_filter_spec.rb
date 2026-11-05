# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/fake_catalog_adapter')

RSpec.describe Vehicle, 'listing source scopes' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:source)  { create(:catalog_source) }

  before { Catalog::IngestionService.new(company: company, source: source).call([FakeCatalogAdapter.home('1')]) }

  let(:original) { company.vehicles.find_by(catalog_source_id: source.id, catalog_source_key: '1') }

  def copy(status: 'available_to_order')
    VehicleCloneFromCatalogService.new(original, status: status, attributes: { model: 'Dealer Name' }).call
  end

  describe '.dealer_preferred' do
    it 'shows the dealer copy instead of the original' do
      mine = copy
      expect(company.vehicles.dealer_preferred).to contain_exactly(mine)
    end

    it 'shows the original when the home has no copy' do
      expect(company.vehicles.dealer_preferred).to contain_exactly(original)
    end

    it 'brings the original back when the copy is deleted' do
      copy.update_columns(is_deleted: true)
      expect(company.vehicles.where(is_deleted: [false, nil]).dealer_preferred).to contain_exactly(original)
    end

    it 'keeps the original to order when the copy is on the lot' do
      mine = copy(status: 'available')
      expect(company.vehicles.where(status: 'available_to_order').dealer_preferred).to contain_exactly(original)
      expect(company.vehicles.where(status: 'available').dealer_preferred).to contain_exactly(mine)
    end
  end

  it 'counts catalog homes as originals and their copies as the dealer\'s' do
    mine = copy
    expect(company.vehicles.originals_only).to contain_exactly(original)
    expect(company.vehicles.synced_only).to contain_exactly(original)
    expect(company.vehicles.dealer_only).to contain_exactly(mine)
  end
end
