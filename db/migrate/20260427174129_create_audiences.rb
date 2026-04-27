class CreateAudiences < ActiveRecord::Migration[8.0]
  def change
    create_table :audiences do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :location, foreign_key: true, index: true
      t.references :created_by_user, foreign_key: { to_table: :users }, index: true

      t.string :name, null: false
      t.text :description
      t.string :source_type, null: false

      t.jsonb :filter_tree, null: false, default: {}
      t.jsonb :exclude_filter_tree, default: {}

      t.integer :estimated_count
      t.datetime :estimated_at

      t.references :generated_from_ai_generation,
                   foreign_key: { to_table: :audience_ai_generations },
                   index: { name: 'idx_audiences_on_ai_gen' }

      t.boolean :is_archived, default: false, null: false
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :audiences, [:company_id, :source_type]
    add_index :audiences, [:company_id, :is_archived]
    add_index :audiences, [:company_id, :name]

    # Now that audiences exists, add the back-reference on audience_ai_generations
    add_reference :audience_ai_generations, :audience,
                  foreign_key: true,
                  index: { name: 'idx_audience_ai_gen_audience' }
  end
end
