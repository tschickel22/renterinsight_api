# frozen_string_literal: true

# Namespace root for the unified knowledge base / site tour system.
#
# The table_name_prefix lets us name models like Knowledge::Feature while the
# underlying table stays knowledge_features — matches the migration names and
# avoids collisions with common top-level names (Feature, Article, Search, etc).
#
# NOTE: Tour / TourStep / UserTourCompletion / MarketingContent are also grouped
# here semantically but live under their natural table names (tours, tour_steps,
# user_tour_completions, marketing_content) because the spec requested those
# unprefixed table names.
module Knowledge
  def self.table_name_prefix
    'knowledge_'
  end
end
