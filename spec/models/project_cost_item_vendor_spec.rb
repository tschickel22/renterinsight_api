# frozen_string_literal: true

require 'rails_helper'

# A cost item's vendor is any vendor the company has, not only contractors, and
# never one belonging to another company: contractor_id arrives from the client.
RSpec.describe ProjectCostItem, type: :model do
  let(:company) { create(:company) }
  let(:project) { Project.create!(company: company, name: 'Lot 4 set-up', status: 'active') }

  def cost_item(vendor_id)
    project.project_cost_items.build(company_id: company.id, description: 'Skirting',
                                     amount: 1200, cost_type: 'materials', status: 'pending',
                                     contractor_id: vendor_id)
  end

  it 'names a supplier, not only a contractor' do
    supplier = Vendor.create!(company: company, name: 'Skirting Supply Co', vendor_type: 'supplier')
    item = cost_item(supplier.id)

    expect(item.save).to be(true)
    expect(item.vendor_name).to eq('Skirting Supply Co')
  end

  it "refuses another company's vendor" do
    elsewhere = Vendor.create!(company: create(:company), name: 'Not Ours', vendor_type: 'contractor')
    item = cost_item(elsewhere.id)

    expect(item.save).to be(false)
    expect(item.errors[:contractor_id]).to include('is not a vendor in this company')
  end
end
