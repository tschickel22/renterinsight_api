class AddUsageToTemplates < ActiveRecord::Migration[8.0]
  # Whether a template is sent as a step inside a nurture sequence, or picked by hand
  # when someone emails or texts one person.
  #
  # This is a different axis from `category`, which is topical (cold_outreach, seasonal,
  # post_sale). Nothing recorded it before, so the UI listed both kinds together and the
  # one-off template picker filled up with drip copy that assumes earlier steps and
  # carries sequence-specific variables.
  #
  # The frontend had been deriving this from nurture_steps.template_id. That is correct
  # for templates already wired into a sequence but wrong for one written for a drip and
  # not yet attached — it read as one-off until first use. A column records intent
  # rather than inferring it after the fact.
  def up
    add_column :templates, :usage, :string, default: 'standalone', null: false
    add_index :templates, :usage
    add_index :templates, %i[company_id usage]

    # Backfill to whatever the derivation would have said, so nothing has to be re-filed
    # by hand: any template a sequence step already points at is nurturing.
    execute <<~SQL.squish
      UPDATE templates
      SET usage = 'nurture'
      WHERE id IN (SELECT DISTINCT template_id FROM nurture_steps WHERE template_id IS NOT NULL)
    SQL
  end

  def down
    remove_index :templates, %i[company_id usage]
    remove_index :templates, :usage
    remove_column :templates, :usage
  end
end
