# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Company, "inventory sharing groups" do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let!(:loc_a) { Location.create!(company_id: company.id, name: "Evangeline", code: "EVA-#{SecureRandom.hex(2)}", active: true) }
  let!(:loc_b) { Location.create!(company_id: company.id, name: "Homes To Geaux", code: "HTG-#{SecureRandom.hex(2)}", active: true) }
  let!(:loc_c) { Location.create!(company_id: company.id, name: "Third", code: "THR-#{SecureRandom.hex(2)}", active: true) }
  let!(:loc_d) { Location.create!(company_id: company.id, name: "Fourth", code: "FOU-#{SecureRandom.hex(2)}", active: true) }

  describe "#inventory_visible_location_ids" do
    it "returns just the input location when no groups are configured" do
      expect(company.inventory_visible_location_ids(loc_a.id)).to eq([loc_a.id])
    end

    it "returns empty for a blank input" do
      expect(company.inventory_visible_location_ids(nil)).to eq([])
      expect(company.inventory_visible_location_ids("")).to eq([])
    end

    it "expands to peers when the location is part of a group" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])

      expect(company.inventory_visible_location_ids(loc_a.id)).to contain_exactly(loc_a.id, loc_b.id)
      expect(company.inventory_visible_location_ids(loc_b.id)).to contain_exactly(loc_a.id, loc_b.id)
    end

    it "leaves untouched a location not in any group" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])
      expect(company.inventory_visible_location_ids(loc_c.id)).to eq([loc_c.id])
    end
  end

  describe "#expand_with_inventory_peers" do
    it "passes through when no groups configured" do
      expect(company.expand_with_inventory_peers([loc_a.id, loc_c.id])).to contain_exactly(loc_a.id, loc_c.id)
    end

    it "adds peers for each input location" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])
      expect(company.expand_with_inventory_peers([loc_a.id])).to contain_exactly(loc_a.id, loc_b.id)
    end

    it "handles blank input safely" do
      expect(company.expand_with_inventory_peers(nil)).to eq([])
      expect(company.expand_with_inventory_peers([])).to eq([])
    end
  end

  describe "#set_inventory_sharing_for_location!" do
    it "creates a symmetric group editable from either side" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])
      # Re-fetch to bypass memoization and prove it's persisted.
      fresh = Company.find(company.id)
      expect(fresh.inventory_visible_location_ids(loc_b.id)).to contain_exactly(loc_a.id, loc_b.id)
    end

    it "merges into an existing group when adding a third member from either side" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])
      company.set_inventory_sharing_for_location!(loc_c.id, [loc_a.id])

      fresh = Company.find(company.id)
      expect(fresh.inventory_visible_location_ids(loc_a.id)).to contain_exactly(loc_a.id, loc_b.id, loc_c.id)
      expect(fresh.inventory_visible_location_ids(loc_b.id)).to contain_exactly(loc_a.id, loc_b.id, loc_c.id)
      expect(fresh.inventory_visible_location_ids(loc_c.id)).to contain_exactly(loc_a.id, loc_b.id, loc_c.id)
    end

    it "removes a location from its group when peers becomes empty" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id, loc_c.id])
      company.set_inventory_sharing_for_location!(loc_a.id, [])

      fresh = Company.find(company.id)
      expect(fresh.inventory_visible_location_ids(loc_a.id)).to eq([loc_a.id])
      # B and C remain grouped together.
      expect(fresh.inventory_visible_location_ids(loc_b.id)).to contain_exactly(loc_b.id, loc_c.id)
    end

    it "deletes a group entirely when it would drop below two members" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])
      company.set_inventory_sharing_for_location!(loc_b.id, [])

      fresh = Company.find(company.id)
      expect(fresh.inventory_sharing_groups).to eq([])
      expect(fresh.inventory_visible_location_ids(loc_a.id)).to eq([loc_a.id])
    end

    it "ignores self-references and non-positive IDs in peer input" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_a.id, 0, -5, loc_b.id])

      fresh = Company.find(company.id)
      expect(fresh.inventory_visible_location_ids(loc_a.id)).to contain_exactly(loc_a.id, loc_b.id)
    end

    it "moves a location out of an old group into a new one when re-edited" do
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_b.id])
      company.set_inventory_sharing_for_location!(loc_a.id, [loc_c.id])

      fresh = Company.find(company.id)
      expect(fresh.inventory_visible_location_ids(loc_a.id)).to contain_exactly(loc_a.id, loc_c.id)
      # B is now alone, so its group should be gone.
      expect(fresh.inventory_visible_location_ids(loc_b.id)).to eq([loc_b.id])
    end
  end
end
