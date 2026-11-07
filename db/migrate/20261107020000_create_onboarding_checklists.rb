# frozen_string_literal: true

# A client's onboarding checklist, inside their own DealerTide (backlog E97):
# the items we add for them, who owes each, what happened to it, and who
# follows along. The standard list is what every new client starts from.
class CreateOnboardingChecklists < ActiveRecord::Migration[8.0]
  def change
    create_table :onboarding_template_items do |t|
      t.string :section, null: false
      t.string :title, null: false
      t.text :detail
      t.string :owed_by, null: false, default: 'client'
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    create_table :onboarding_items do |t|
      t.references :company, null: false, foreign_key: true
      t.references :template_item, foreign_key: { to_table: :onboarding_template_items }
      t.string :section, null: false
      t.string :title, null: false
      t.text :detail
      t.string :owed_by, null: false, default: 'client'
      t.string :status, null: false, default: 'open'
      t.references :assignee, foreign_key: { to_table: :users }
      t.date :due_on
      t.datetime :done_at
      t.references :done_by, foreign_key: { to_table: :users }
      t.references :created_by, foreign_key: { to_table: :users }
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :onboarding_events do |t|
      t.references :company, null: false, foreign_key: true
      t.references :onboarding_item, foreign_key: { on_delete: :nullify }
      t.references :user, foreign_key: true
      t.string :kind, null: false
      t.string :side, null: false
      t.text :body
      t.timestamps
    end
    add_index :onboarding_events, %i[company_id created_at]

    create_table :onboarding_followers do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :onboarding_followers, %i[company_id user_id], unique: true
  end
end
