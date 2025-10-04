class QuickfixTagsAndAssignments < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:tags)
      create_table :tags do |t|
        t.string  :name, null: false
        t.string  :description
        t.string  :color, default: '#6B7280'
        t.string  :category
        t.text    :tag_type      # JSON array as text for SQLite
        t.boolean :is_active, default: true
        t.boolean :is_system, default: false
        t.integer :usage_count, default: 0
        t.string  :created_by
        t.timestamps
      end
      add_index :tags, :name, unique: true
    else
      add_column :tags, :description, :string unless column_exists?(:tags, :description)
      add_column :tags, :color, :string, default: '#6B7280' unless column_exists?(:tags, :color)
      add_column :tags, :category, :string unless column_exists?(:tags, :category)
      add_column :tags, :tag_type, :text unless column_exists?(:tags, :tag_type)
      add_column :tags, :is_active, :boolean, default: true unless column_exists?(:tags, :is_active)
      add_column :tags, :is_system, :boolean, default: false unless column_exists?(:tags, :is_system)
      add_column :tags, :usage_count, :integer, default: 0 unless column_exists?(:tags, :usage_count)
      add_column :tags, :created_by, :string unless column_exists?(:tags, :created_by)
      add_index  :tags, :name, unique: true unless index_exists?(:tags, :name, unique: true)
    end

    unless table_exists?(:tag_assignments)
      create_table :tag_assignments do |t|
        t.references :tag, null: false, foreign_key: false
        t.string  :entity_type, null: false
        t.integer :entity_id, null: false
        t.string  :assigned_by
        t.datetime :assigned_at
        t.timestamps
      end
      add_index :tag_assignments, [:entity_type, :entity_id]
      add_index :tag_assignments, [:tag_id, :entity_type, :entity_id], name: 'idx_tag_assignments_composite'
    else
      add_column :tag_assignments, :assigned_by, :string unless column_exists?(:tag_assignments, :assigned_by)
      add_column :tag_assignments, :assigned_at, :datetime unless column_exists?(:tag_assignments, :assigned_at)
      add_index  :tag_assignments, [:entity_type, :entity_id] unless index_exists?(:tag_assignments, [:entity_type, :entity_id])
      unless index_exists?(:tag_assignments, [:tag_id, :entity_type, :entity_id], name: 'idx_tag_assignments_composite')
        add_index :tag_assignments, [:tag_id, :entity_type, :entity_id], name: 'idx_tag_assignments_composite'
      end
    end
  end

  def down
    # no-op (safe quickfix)
  end
end
