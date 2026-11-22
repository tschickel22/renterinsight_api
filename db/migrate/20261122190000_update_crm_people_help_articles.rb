# frozen_string_literal: true

# Rewrites Converting a Lead, Managing Accounts and Managing Contacts from
# db/guide/crm_people_articles.yml for the people card work (Tom, 2026-11-22).
# Each one is replaced only while it still holds its old text (`replaces_when`),
# so a later rewrite in Knowledge admin is left alone.
class UpdateCrmPeopleHelpArticles < ActiveRecord::Migration[8.0]
  def up
    data = YAML.safe_load_file(Rails.root.join('db/guide/crm_people_articles.yml'))
    Array(data['articles']).each do |a|
      article = Knowledge::Article.find_by(slug: a['slug'])
      next say("#{a['slug']}: not loaded") unless article
      next say("#{a['slug']}: already rewritten, left alone") unless article.content.to_s.include?(a['replaces_when'])

      article.update_columns(title: a['title'], excerpt: a['excerpt'], content: a['content'], updated_at: Time.current)
      say "#{a['slug']}: updated"
    end
  end

  def down
    # Articles are content; leave them.
  end
end
