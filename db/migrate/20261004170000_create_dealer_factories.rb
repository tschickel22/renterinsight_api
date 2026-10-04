# frozen_string_literal: true

# TrueBuild factory readiness (backlog E64). A platform admin releases a
# factory once its price book, drawings and checks are good enough to sell,
# and gives released factories to dealers one by one. Until now every dealer
# with pricing set up saw every factory with a published price book.
#
# So nothing disappears for anyone, factories with a published price book are
# released now, and every dealer that could see them is given them.
class CreateDealerFactories < ActiveRecord::Migration[8.0]
  def up
    add_column :factories, :truebuild_released_at, :datetime
    add_column :factories, :truebuild_released_by_id, :bigint
    add_column :factories, :truebuild_release_note, :text

    create_table :dealer_factories do |t|
      t.references :company, null: false, foreign_key: true
      t.references :factory, null: false, foreign_key: true
      t.bigint :added_by_id
      t.timestamps
    end
    add_index :dealer_factories, %i[company_id factory_id], unique: true

    execute <<~SQL.squish
      UPDATE factories SET truebuild_released_at = NOW(),
        truebuild_release_note = 'Released when the readiness board was added: dealers could already see it.'
      WHERE id IN (
        SELECT DISTINCT cp.factory_id FROM catalog_plans cp
        JOIN catalog_plan_variants v ON v.catalog_plan_id = cp.id
        JOIN catalog_variant_prices p ON p.catalog_plan_variant_id = v.id
        JOIN catalog_price_books b ON b.id = p.catalog_price_book_id
        WHERE b.status = 'published' AND cp.factory_id IS NOT NULL)
    SQL

    execute <<~SQL.squish
      INSERT INTO dealer_factories (company_id, factory_id, created_at, updated_at)
      SELECT c.company_id, f.id, NOW(), NOW()
      FROM (SELECT company_id FROM dealer_markup_rules WHERE active
            UNION SELECT company_id FROM dealer_catalog_terms) c
      CROSS JOIN factories f
      WHERE f.truebuild_released_at IS NOT NULL
      ON CONFLICT DO NOTHING
    SQL
  end

  def down
    drop_table :dealer_factories
    remove_column :factories, :truebuild_release_note
    remove_column :factories, :truebuild_released_by_id
    remove_column :factories, :truebuild_released_at
  end
end
