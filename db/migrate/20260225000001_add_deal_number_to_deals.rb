class AddDealNumberToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :deal_number, :string
    add_index :deals, [:company_id, :deal_number], unique: true, name: 'index_deals_on_company_id_and_deal_number'

    # Backfill existing deals with sequential numbers per company
    reversible do |dir|
      dir.up do
        execute <<-SQL
          WITH numbered AS (
            SELECT id,
                   company_id,
                   ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY created_at, id) AS rn
            FROM deals
            WHERE deal_number IS NULL
          )
          UPDATE deals
          SET deal_number = 'D-' || LPAD(numbered.rn::text, 6, '0')
          FROM numbered
          WHERE deals.id = numbered.id
        SQL
      end
    end
  end
end
