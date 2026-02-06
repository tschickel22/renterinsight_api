# frozen_string_literal: true

class CreateDefaultBinsForExistingInventory < ActiveRecord::Migration[8.0]
  def up
    # For each location, create a DEFAULT bin and assign existing inventory to it
    Location.find_each do |location|
      # Skip if DEFAULT bin already exists
      next if location.bins.exists?(bin_code: 'DEFAULT')

      # Create DEFAULT bin
      default_bin = location.bins.create!(
        bin_code: 'DEFAULT',
        label: 'Default Bin (Unassigned)',
        bin_type: 'standard',
        is_default: true,
        capacity_cubic_feet: 999999,
        active: true,
        notes: 'Auto-created bin for existing inventory'
      )

      puts "Created DEFAULT bin for location: #{location.name} (ID: #{location.id})"

      # Find all parts with inventory at this location (via InventoryTransaction)
      part_ids = InventoryTransaction
        .where(company_id: location.company_id, location_id: location.id)
        .distinct
        .pluck(:part_id)

      part_ids.each do |part_id|
        # Calculate total quantity for this part at this location
        total_qty = InventoryTransaction
          .where(company_id: location.company_id, location_id: location.id, part_id: part_id)
          .sum(:quantity)

        next if total_qty <= 0

        # Find or create stock balance for this part
        stock_balance = StockBalance.find_or_initialize_by(
          company_id: location.company_id,
          part_id: part_id,
          location_id: location.id,
          bin_id: default_bin.id
        )

        # If bin_id was nil, update it
        if stock_balance.new_record?
          stock_balance.assign_attributes(
            on_hand: total_qty,
            reserved: 0,
            available: total_qty
          )
          stock_balance.save!
          puts "  - Assigned #{total_qty} units of Part #{part_id} to DEFAULT bin"
        else
          # Stock balance already exists with bin_id, add to it
          stock_balance.on_hand += total_qty
          stock_balance.available += total_qty
          stock_balance.save!
          puts "  - Updated #{stock_balance.on_hand} units of Part #{part_id} in DEFAULT bin"
        end
      end

      # Also handle any existing stock_balances with nil bin_id
      StockBalance.where(
        company_id: location.company_id,
        location_id: location.id,
        bin_id: nil
      ).find_each do |balance|
        balance.update!(bin_id: default_bin.id)
        puts "  - Moved existing stock balance (Part #{balance.part_id}) to DEFAULT bin"
      end
    end

    puts "\n✅ DEFAULT bins created successfully!"
  end

  def down
    # Remove DEFAULT bins that have no inventory
    Bin.where(bin_code: 'DEFAULT', is_default: true).find_each do |bin|
      if bin.stock_balances.where('on_hand > 0').empty?
        bin.destroy
        puts "Removed empty DEFAULT bin for location: #{bin.location.name}"
      else
        puts "⚠️  Kept DEFAULT bin for location: #{bin.location.name} (has inventory)"
      end
    end
  end
end
