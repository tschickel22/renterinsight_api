class CreateWebsiteFeaturedHomes < ActiveRecord::Migration[8.0]
  # Homes a dealer hand-picks for a website's Featured Homes section, in the
  # order they chose, with copy written for the site. The title and
  # description here never write back to the inventory record.
  def change
    create_table :website_featured_homes do |t|
      t.references :website, null: false, foreign_key: true
      t.references :vehicle, null: false, foreign_key: true
      t.integer :position, default: 0, null: false
      t.string :title
      t.text :description
      t.timestamps
    end

    add_index :website_featured_homes, [:website_id, :vehicle_id], unique: true
    add_index :website_featured_homes, [:website_id, :position]
  end
end
