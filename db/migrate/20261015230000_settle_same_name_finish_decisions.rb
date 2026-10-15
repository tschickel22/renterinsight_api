# frozen_string_literal: true

# Claude's "same finish" decisions whose options carry the very same name
# (Topeka's "Lisola" and "Lisola") asked an admin something with one answer.
# They are kept as they are, marked settled so they leave the review list.
# OptionReview settles new ones the same way.
class SettleSameNameFinishDecisions < ActiveRecord::Migration[8.0]
  def up
    settled = execute(<<~SQL).cmd_tuples
      UPDATE catalog_option_decisions d SET source = 'code', reviewed_at = NOW(), updated_at = NOW()
      WHERE d.kind = 'same_finish' AND d.reviewed_at IS NULL AND d.suggestion IN (
        SELECT s.suggestion FROM catalog_option_decisions s
        JOIN catalog_options o ON o.key = s.option_key AND o.manufacturer_id = s.manufacturer_id
        WHERE s.kind = 'same_finish' AND s.suggestion IS NOT NULL
        GROUP BY s.suggestion
        HAVING COUNT(DISTINCT regexp_replace(lower(o.name), '[^a-z0-9]', '', 'g')) = 1
      )
    SQL
    say "#{settled} same name decisions settled"
  end

  def down; end
end
