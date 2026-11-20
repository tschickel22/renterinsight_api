# frozen_string_literal: true

require 'digest'

# Project help for E106 to E109 (who hears, scope changes, contractor dates,
# how a cost was paid, the projects calendar), from db/guide/project_articles.yml.
# Inserts the new article, and rewrites a changed one only while its text is a
# version we know (as loaded, or with the screenshot lines and the quote
# details note added since); anything else was edited by hand in Knowledge
# admin, so it is left alone and listed.
class UpdateProjectHelpArticlesForE106E109 < ActiveRecord::Migration[8.0]
  SLUGS = %w[
    projects-overview tasks-and-phases get-bids-on-a-phase award-a-bid review-updates project-notices
    contractor-invoices-to-bills project-job-costs send-job-to-installer installer-prices installer-working-jobs
    contractor-portal-for-contractors
  ].freeze

  # MD5 of each article's text as loaded on 2026-10-30, and as it stood on
  # staging on 2026-11-20 (screenshot lines and quote details added), with
  # {{shot:}} lines and all whitespace removed. Any other text is a hand edit.
  KNOWN = {
    'projects-overview' => %w[f16f59c9a8cacd4a1b03e942e746f0a9],
    'tasks-and-phases' => %w[d1f338a610b79bf5f3348cb75e88a105],
    'get-bids-on-a-phase' => %w[27202067b962b02f198bd277bc53a400],
    'award-a-bid' => %w[32eb66708be696cad5759afbfe9cc13a],
    'review-updates' => %w[f03b6455b6fe0114bf84a58fdc49bdb4],
    'project-notices' => %w[2ac91205d8cbb5abc04cdd1a62529a80],
    'contractor-invoices-to-bills' => %w[b72c0758a7ffa924a35d10322a000b8c],
    'project-job-costs' => %w[ae1b90c033f3dd34472ac6865a2e2b78],
    'send-job-to-installer' => %w[bb4213b0af1bc7598b7bcd82fcefab89 f1e5fe2b98d5305b011ba9814a23d884],
    'installer-prices' => %w[2c92797dcdfe233f12881a5e7471ee85],
    'installer-working-jobs' => %w[675590c43658c47fb5d387ed15d34749 fc94563bf13d4aa972719a8272e53f07],
    'contractor-portal-for-contractors' => %w[28f6a45f028fafe5844b03f1fc181bc1],
  }.freeze

  def up
    path = Rails.root.join('db/guide/project_articles.yml')
    result = Guide::ArticleLoader.load!(path)
    say "created: #{result.created.join(', ').presence || 'none'}"

    articles = Array(YAML.safe_load_file(path)['articles']).index_by { |a| a['slug'] }
    SLUGS.each do |slug|
      article = Knowledge::Article.find_by(slug: slug)
      next say("#{slug}: not loaded") unless article
      digest = Digest::MD5.hexdigest(article.content.to_s.gsub(/\{\{shot:[^\n]*\}\}/, '').gsub(/\s+/, ''))
      next say("#{slug}: edited in Knowledge admin, left alone") unless KNOWN.fetch(slug).include?(digest)

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
