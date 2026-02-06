# frozen_string_literal: true

class AddUniqueIndexToStockBalances < ActiveRecord::Migration[8.0]
  def up
    # First, fix duplicate stock_balances by consolidating them
    say "Consolidating duplicate stock_balances..."
    
    # Find duplicates grouped by (company_id, part_id, location_id, bin_id)
    duplicates = execute(<<~SQL).to_a
      SELECT company_id, part_id, location_id, COALESCE(bin_id, -1) as bin_key, array_agg(id) as ids, COUNT(*) as count
      FROM stock_balances
      GROUP BY company_id, part_id, location_id, COALESCE(bin_id, -1)
      HAVING COUNT(*) > 1
    SQL
    
    duplicates.each do |dup|
      ids = dup['ids'].gsub(/[{}]/, '').split(',').map(&:to_i)
      keeper_id = ids.first
      duplicate_ids = ids[1..-1]
      
      say "  Consolidating stock_balance IDs #{ids.join(', ')} -> keeping #{keeper_id}"
      
      # Get the keeper record
      keeper = execute("SELECT * FROM stock_balances WHERE id = #{keeper_id}").first
      
      # Sum quantities from all duplicates
      total_on_hand = 0
      total_reserved = 0
      
      ids.each do |id|
        record = execute("SELECT on_hand, reserved FROM stock_balances WHERE id = #{id}").first
        total_on_hand += record['on_hand'].to_f
        total_reserved += record['reserved'].to_f
      end
      
      # Update keeper with consolidated quantities
      execute(<<~SQL)
        UPDATE stock_balances
        SET on_hand = #{total_on_hand},
            reserved = #{total_reserved},
            available = #{total_on_hand - total_reserved}
        WHERE id = #{keeper_id}
      SQL
      
      # Delete duplicates
      execute("DELETE FROM stock_balances WHERE id IN (#{duplicate_ids.join(',')})")
    end
    
    say "Fixed #{duplicates.count} duplicate stock_balance groups"
    
    # Now add unique index to prevent future duplicates
    add_index :stock_balances, 
              [:company_id, :part_id, :location_id, :bin_id],
              unique: true,
              name: 'index_stock_balances_on_company_part_location_bin',
              where: 'bin_id IS NOT NULL'
    
    # Separate index for NULL bin_id (default bin)
    add_index :stock_balances,
              [:company_id, :part_id, :location_id],
              unique: true,
              name: 'index_stock_balances_on_company_part_location_null_bin',
              where: 'bin_id IS NULL'
  end
  
  def down
    remove_index :stock_balances, name: 'index_stock_balances_on_company_part_location_bin'
    remove_index :stock_balances, name: 'index_stock_balances_on_company_part_location_null_bin'
  end
end
