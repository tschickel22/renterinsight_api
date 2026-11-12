# frozen_string_literal: true

# The Customers and vendors step gained Don't bring over and says nothing needs
# approving. Rewrites the step by step article from
# db/guide/quickbooks_switch_articles.yml where nobody has edited it in
# Knowledge admin (updated_at still equal to created_at).
class UpdateQuickbooksSwitchLeaveOutHelp < ActiveRecord::Migration[8.0]
  SLUGS = %w[quickbooks-switch-steps].freeze

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
