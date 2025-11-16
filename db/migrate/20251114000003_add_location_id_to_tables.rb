# frozen_string_literal: true

class AddLocationIdToTables < ActiveRecord::Migration[8.0]
  def up
    # Add location_id to vehicles (if not exists)
    unless column_exists?(:vehicles, :location_id)
      add_column :vehicles, :location_id, :bigint
      add_index :vehicles, :location_id
      add_index :vehicles, [:company_id, :location_id]
      add_foreign_key :vehicles, :locations, column: :location_id
    end

    # Add location_id to listings (if not exists)
    unless column_exists?(:listings, :location_id)
      add_column :listings, :location_id, :bigint
      add_index :listings, :location_id
      add_index :listings, [:company_id, :location_id]
      add_foreign_key :listings, :locations, column: :location_id
    end

    # Add location_id to leads (if not exists)
    unless column_exists?(:leads, :location_id)
      add_column :leads, :location_id, :bigint
      add_index :leads, :location_id
      add_index :leads, [:company_id, :location_id]
      add_foreign_key :leads, :locations, column: :location_id
    end

    # Add location_id to deals (if not exists)
    unless column_exists?(:deals, :location_id)
      add_column :deals, :location_id, :bigint
      add_index :deals, :location_id
      add_index :deals, [:company_id, :location_id]
      add_foreign_key :deals, :locations, column: :location_id
    end

    # Add location_id to accounts (if not exists)
    unless column_exists?(:accounts, :location_id)
      add_column :accounts, :location_id, :bigint
      add_index :accounts, :location_id
      add_index :accounts, [:company_id, :location_id]
      add_foreign_key :accounts, :locations, column: :location_id
    end

    # Add location_id to contacts (if not exists)
    unless column_exists?(:contacts, :location_id)
      add_column :contacts, :location_id, :bigint
      add_index :contacts, :location_id
      add_index :contacts, [:company_id, :location_id]
      add_foreign_key :contacts, :locations, column: :location_id
    end

    # Add location_id to service_tickets (if not exists)
    unless column_exists?(:service_tickets, :location_id)
      add_column :service_tickets, :location_id, :bigint
      add_index :service_tickets, :location_id
      add_index :service_tickets, [:company_id, :location_id]
      add_foreign_key :service_tickets, :locations, column: :location_id
    end

    # Add location_id to quotes (if not exists)
    unless column_exists?(:quotes, :location_id)
      add_column :quotes, :location_id, :bigint
      add_index :quotes, :location_id
      add_index :quotes, [:company_id, :location_id]
      add_foreign_key :quotes, :locations, column: :location_id
    end
  end

  def down
    # Remove location_id columns (if they exist)
    if column_exists?(:vehicles, :location_id)
      remove_foreign_key :vehicles, column: :location_id if foreign_key_exists?(:vehicles, :locations)
      remove_index :vehicles, :location_id if index_exists?(:vehicles, :location_id)
      remove_index :vehicles, [:company_id, :location_id] if index_exists?(:vehicles, [:company_id, :location_id])
      remove_column :vehicles, :location_id
    end

    if column_exists?(:listings, :location_id)
      remove_foreign_key :listings, column: :location_id if foreign_key_exists?(:listings, :locations)
      remove_index :listings, :location_id if index_exists?(:listings, :location_id)
      remove_index :listings, [:company_id, :location_id] if index_exists?(:listings, [:company_id, :location_id])
      remove_column :listings, :location_id
    end

    if column_exists?(:leads, :location_id)
      remove_foreign_key :leads, column: :location_id if foreign_key_exists?(:leads, :locations)
      remove_index :leads, :location_id if index_exists?(:leads, :location_id)
      remove_index :leads, [:company_id, :location_id] if index_exists?(:leads, [:company_id, :location_id])
      remove_column :leads, :location_id
    end

    if column_exists?(:deals, :location_id)
      remove_foreign_key :deals, column: :location_id if foreign_key_exists?(:deals, :locations)
      remove_index :deals, :location_id if index_exists?(:deals, :location_id)
      remove_index :deals, [:company_id, :location_id] if index_exists?(:deals, [:company_id, :location_id])
      remove_column :deals, :location_id
    end

    if column_exists?(:accounts, :location_id)
      remove_foreign_key :accounts, column: :location_id if foreign_key_exists?(:accounts, :locations)
      remove_index :accounts, :location_id if index_exists?(:accounts, :location_id)
      remove_index :accounts, [:company_id, :location_id] if index_exists?(:accounts, [:company_id, :location_id])
      remove_column :accounts, :location_id
    end

    if column_exists?(:contacts, :location_id)
      remove_foreign_key :contacts, column: :location_id if foreign_key_exists?(:contacts, :locations)
      remove_index :contacts, :location_id if index_exists?(:contacts, :location_id)
      remove_index :contacts, [:company_id, :location_id] if index_exists?(:contacts, [:company_id, :location_id])
      remove_column :contacts, :location_id
    end

    if column_exists?(:service_tickets, :location_id)
      remove_foreign_key :service_tickets, column: :location_id if foreign_key_exists?(:service_tickets, :locations)
      remove_index :service_tickets, :location_id if index_exists?(:service_tickets, :location_id)
      remove_index :service_tickets, [:company_id, :location_id] if index_exists?(:service_tickets, [:company_id, :location_id])
      remove_column :service_tickets, :location_id
    end

    if column_exists?(:quotes, :location_id)
      remove_foreign_key :quotes, column: :location_id if foreign_key_exists?(:quotes, :locations)
      remove_index :quotes, :location_id if index_exists?(:quotes, :location_id)
      remove_index :quotes, [:company_id, :location_id] if index_exists?(:quotes, [:company_id, :location_id])
      remove_column :quotes, :location_id
    end
  end
end
