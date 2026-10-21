# frozen_string_literal: true

# A site's client_access_level is now either a level a platform admin chose for
# that site, which wins over the dealer's plan, or NULL, meaning "follow the plan".
#
# It was NOT NULL DEFAULT 3 and capped by the plan, so every site read "Full
# Editor" whether anyone chose it or not, and choosing Full Editor for a dealer
# on a View Only plan silently did nothing. A 3 here cannot be told apart from
# the default, and the plan capped it anyway, so 3 becomes NULL: every such site
# behaves exactly as before. Lower levels were chosen deliberately and are kept.
class LetWebsitesFollowThePlanAccessLevel < ActiveRecord::Migration[8.0]
  def up
    change_column_null :websites, :client_access_level, true
    change_column_default :websites, :client_access_level, from: 3, to: nil
    execute 'UPDATE websites SET client_access_level = NULL WHERE client_access_level = 3'
  end

  def down
    execute 'UPDATE websites SET client_access_level = 3 WHERE client_access_level IS NULL'
    change_column_default :websites, :client_access_level, from: nil, to: 3
    change_column_null :websites, :client_access_level, false
  end
end
