# frozen_string_literal: true

# The TrueBuild Deal Sheet's "Less down payment" used to write deals.down_payment,
# which is now the Deposit. Deals that have a sheet meant it as the contract's down
# payment, so it moves to contract_down_payment and their contracts keep the same
# unpaid balance. Deals without a sheet are left alone: their figure is a deposit.
class CarryDealSheetDownPayments < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE deals SET contract_down_payment = down_payment
      WHERE contract_down_payment IS NULL AND down_payment > 0
        AND EXISTS (SELECT 1 FROM deal_home_builds b WHERE b.deal_id = deals.id)
    SQL
  end

  def down; end
end
