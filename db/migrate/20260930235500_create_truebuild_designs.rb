# frozen_string_literal: true

# A home a buyer designed on a dealer's website: the model, the options they
# chose, and the price they were shown, frozen at save. The public token is the
# share link. The lead comes through the dealer's intake form like any other.
class CreateTruebuildDesigns < ActiveRecord::Migration[8.0]
  def change
    create_table :truebuild_designs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :catalog_plan_variant, null: false, foreign_key: true
      t.references :vehicle, foreign_key: true
      t.references :lead, foreign_key: true
      t.references :intake_submission, foreign_key: true
      t.references :catalog_price_book, foreign_key: true
      t.string :public_token, null: false
      t.string :name
      t.string :status, null: false, default: 'saved'
      t.jsonb :option_ids, null: false, default: []
      t.jsonb :price_snapshot, null: false, default: {}
      t.string :buyer_email
      t.string :buyer_name
      t.integer :view_count, null: false, default: 0
      t.datetime :last_viewed_at
      t.integer :share_count, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :truebuild_designs, :public_token, unique: true
    add_index :truebuild_designs, %i[company_id created_at]
  end
end
