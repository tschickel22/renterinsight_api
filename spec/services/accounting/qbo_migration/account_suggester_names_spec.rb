# frozen_string_literal: true

require 'rails_helper'

# The deterministic "same number" match must also agree on what the account
# is for. Found in the 2026-10-03 browser test: shared generic words paired
# unrelated accounts and would have been confirmed by Confirm all suggested.
RSpec.describe Accounting::QboMigration::AccountSuggester do
  subject(:suggester) { described_class.allocate }

  def agree?(left, right)
    suggester.send(:names_agree?, left, right)
  end

  it 'does not pair accounts that only share a generic word' do
    expect(agree?('Land / Lot Inventory', 'Parts and Supplies Inventory')).to be(false)
    expect(agree?('Vehicle Expense - Fuel', 'Depreciation Expense')).to be(false)
    expect(agree?('Inventory - Used Homes', 'Pre-Owned Home Inventory')).to be(false)
  end

  it 'still pairs accounts that are clearly the same' do
    expect(agree?('Inventory - New Homes', 'New Home Inventory')).to be(true)
    expect(agree?('Sales Tax Payable', 'Sales Tax Payable')).to be(true)
    expect(agree?('Cost of Homes Sold - New', 'Cost of New Homes Sold')).to be(true)
    expect(agree?('Prepaid Insurance', 'Prepaid Insurance')).to be(true)
  end

  it 'never matches a name made only of generic words' do
    expect(agree?('Inventory', 'Inventory')).to be(false)
  end
end
