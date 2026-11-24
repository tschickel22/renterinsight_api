# frozen_string_literal: true

# A sale no longer pretends to post a floor plan payoff (it never did: the
# code read a field deals do not have). The floor plan note now says how the
# payoff is booked: by categorizing the payoff bank line (Tom, 2026-11-24).
# Rewrites the loaded note from db/guide/how_it_works_accounting.yml only
# while it lacks that section, so an edit in Knowledge admin is kept.
class UpdateFloorPlanHelpNote < ActiveRecord::Migration[8.0]
  SLUG = 'how-it-works-floor-plan-homes'

  def up
    article = Knowledge::Article.find_by(slug: SLUG)
    return say("#{SLUG}: not loaded") unless article
    return say("#{SLUG}: already has the payoff section") if article.content.to_s.include?('## Paying off the lender')
    return say("#{SLUG}: edited by hand, left alone") unless article.content.to_s.include?("Floor plan interest is never part of a home's cost of sale.")

    data = YAML.safe_load_file(Rails.root.join('db/guide/how_it_works_accounting.yml'))
    note = Array(data['articles']).find { |a| a['slug'] == SLUG }
    article.update_columns(content: note['content'], updated_at: Time.current)
    say "#{SLUG}: updated"
  end

  def down
    # Articles are content; leave them.
  end
end
