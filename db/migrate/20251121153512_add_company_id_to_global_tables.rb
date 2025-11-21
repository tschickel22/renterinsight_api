# frozen_string_literal: true
# Migration to add company_id to sources, tags, and territories for proper multi-tenant isolation

class AddCompanyIdToGlobalTables < ActiveRecord::Migration[8.0]
  def up
    # ============================================
    # SOURCES TABLE
    # ============================================
    unless column_exists?(:sources, :company_id)
      add_column :sources, :company_id, :bigint
      add_index :sources, :company_id
      add_index :sources, [:company_id, :name], name: 'index_sources_on_company_id_and_name'
    end

    # ============================================
    # TAGS TABLE
    # ============================================
    unless column_exists?(:tags, :company_id)
      add_column :tags, :company_id, :bigint
      add_index :tags, :company_id
      add_index :tags, [:company_id, :name], name: 'index_tags_on_company_id_and_name'
      
      # Remove the old unique index on name (global uniqueness)
      # and replace with company-scoped uniqueness
      if index_exists?(:tags, :name, name: 'index_tags_on_name')
        remove_index :tags, name: 'index_tags_on_name'
      end
      
      # Add unique index scoped to company (allow same tag name in different companies)
      # NULL company_id means platform-level tag
      add_index :tags, [:company_id, :name], unique: true, 
                name: 'index_tags_unique_per_company',
                where: 'company_id IS NOT NULL'
    end

    # ============================================
    # TERRITORIES TABLE
    # ============================================
    unless column_exists?(:territories, :company_id)
      add_column :territories, :company_id, :bigint
      add_index :territories, :company_id
      add_index :territories, [:company_id, :name], name: 'index_territories_on_company_id_and_name'
      
      # Remove the old unique index on name (global uniqueness)
      if index_exists?(:territories, :name, name: 'index_territories_on_name')
        remove_index :territories, name: 'index_territories_on_name'
      end
      
      # Add unique index scoped to company
      add_index :territories, [:company_id, :name], unique: true,
                name: 'index_territories_unique_per_company',
                where: 'company_id IS NOT NULL'
    end

    # ============================================
    # TAG_ASSIGNMENTS TABLE - Add company_id for faster queries
    # ============================================
    unless column_exists?(:tag_assignments, :company_id)
      add_column :tag_assignments, :company_id, :bigint
      add_index :tag_assignments, :company_id
    end
  end

  def down
    # SOURCES
    if column_exists?(:sources, :company_id)
      remove_index :sources, :company_id if index_exists?(:sources, :company_id)
      remove_index :sources, name: 'index_sources_on_company_id_and_name' if index_exists?(:sources, name: 'index_sources_on_company_id_and_name')
      remove_column :sources, :company_id
    end

    # TAGS
    if column_exists?(:tags, :company_id)
      remove_index :tags, name: 'index_tags_unique_per_company' if index_exists?(:tags, name: 'index_tags_unique_per_company')
      remove_index :tags, name: 'index_tags_on_company_id_and_name' if index_exists?(:tags, name: 'index_tags_on_company_id_and_name')
      remove_index :tags, :company_id if index_exists?(:tags, :company_id)
      remove_column :tags, :company_id
      
      # Restore global unique index
      add_index :tags, :name, unique: true unless index_exists?(:tags, :name)
    end

    # TERRITORIES
    if column_exists?(:territories, :company_id)
      remove_index :territories, name: 'index_territories_unique_per_company' if index_exists?(:territories, name: 'index_territories_unique_per_company')
      remove_index :territories, name: 'index_territories_on_company_id_and_name' if index_exists?(:territories, name: 'index_territories_on_company_id_and_name')
      remove_index :territories, :company_id if index_exists?(:territories, :company_id)
      remove_column :territories, :company_id
      
      # Restore global unique index
      add_index :territories, :name, unique: true unless index_exists?(:territories, :name)
    end

    # TAG_ASSIGNMENTS
    if column_exists?(:tag_assignments, :company_id)
      remove_index :tag_assignments, :company_id if index_exists?(:tag_assignments, :company_id)
      remove_column :tag_assignments, :company_id
    end
  end
end
