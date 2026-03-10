class FixEntityBuyersUniqueIndex < ActiveRecord::Migration[8.0]
  def change
    # Remove the absolute unique index (blocks re-adding soft-deleted contacts)
    remove_index :entity_buyers, name: 'index_entity_buyers_on_contact_buyable'

    # Add partial unique index — only enforced on active (non-deleted) records
    add_index :entity_buyers, [:contact_id, :buyable_type, :buyable_id],
              name: 'index_entity_buyers_on_contact_buyable',
              unique: true,
              where: "is_deleted = false"
  end
end
