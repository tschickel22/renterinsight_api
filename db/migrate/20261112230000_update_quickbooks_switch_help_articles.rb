# frozen_string_literal: true

# The QuickBooks switch articles gained customer and vendor matching and the
# QuickBooks sync being turned off (db/guide/quickbooks_switch_articles.yml).
# The loader only inserts, so this rewrites the ones already loaded, but only
# an article nobody has edited in Knowledge admin since it was loaded
# (updated_at still equal to created_at); an edited one is left alone.
class UpdateQuickbooksSwitchHelpArticles < ActiveRecord::Migration[8.0]
  SLUGS = %w[quickbooks-switch-overview quickbooks-switch-steps].freeze

  def up
    data = YAML.safe_load_file(Rails.root.join('db/guide/quickbooks_switch_articles.yml'))
    articles = Array(data['articles']).index_by { |a| a['slug'] }
    SLUGS.each do |slug|
      article = Knowledge::Article.find_by(slug: slug)
      next say("#{slug}: not loaded") unless article
      next say("#{slug}: edited in Knowledge admin, left alone") if (article.updated_at - article.created_at).abs > 1

      a = articles.fetch(slug)
      now = Time.current
      article.update_columns(content: a['content'], excerpt: a['excerpt'], title: a['title'], updated_at: now, created_at: now)
      say "#{slug}: updated"
    end
  end

  def down
    # Articles are content; leave them.
  end
end
