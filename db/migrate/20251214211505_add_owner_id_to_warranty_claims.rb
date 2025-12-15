class AddOwnerIdToWarrantyClaims < ActiveRecord::Migration[8.0]
  def change
    add_column :warranty_claims, :owner_id, :integer
    add_index :warranty_claims, :owner_id
    
    # Backfill from service tickets - inherit owner from service ticket's assigned_to
    # Only convert values that are numeric (user IDs)
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE warranty_claims
          SET owner_id = CAST(service_tickets.assigned_to AS INTEGER)
          FROM service_tickets
          WHERE warranty_claims.service_ticket_id = service_tickets.id
          AND service_tickets.assigned_to IS NOT NULL
          AND service_tickets.assigned_to != ''
          AND service_tickets.assigned_to ~ '^[0-9]+$'
        SQL
      end
    end
  end
end
