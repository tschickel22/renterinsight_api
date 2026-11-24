# frozen_string_literal: true

# Commission is now booked once, at deal approval (Accounting::DealCommissionAccrual,
# Tom 2026-11-24), not in the closing entry. Rewrites the "The books" part of the
# commission note from db/guide/how_it_works_commissions.yml, only while the loaded
# note still says the closing entry books it, so an edit in Knowledge admin is kept.
class UpdateCommissionBooksHelpNote < ActiveRecord::Migration[8.0]
  SLUG = 'how-it-works-commission-payable-and-paid'
  OLD = 'the closing journal entry includes the **Commission Amount**'

  def up
    article = Knowledge::Article.find_by(slug: SLUG)
    return say("#{SLUG}: not loaded") unless article
    return say("#{SLUG}: already rewritten, left alone") unless article.content.to_s.include?(OLD)

    data = YAML.safe_load_file(Rails.root.join('db/guide/how_it_works_commissions.yml'))
    note = Array(data['articles']).find { |a| a['slug'] == SLUG }
    article.update_columns(content: note['content'], excerpt: note['excerpt'], updated_at: Time.current)
    say "#{SLUG}: updated"
  end

  def down
    # Articles are content; leave them.
  end
end
