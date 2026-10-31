# frozen_string_literal: true

# A screenshot in help articles (backlog E89): a recipe for taking it and
# the pictures the nightly run took, at desktop and mobile size. Nobody
# takes these by hand; scripts/screenshot-capture.cjs in the frontend repo
# plays each recipe on staging in the demo company every morning, and a
# picture that changed replaces the old one by itself.
#
# An article shows one on a line of its own:
#   {{shot: deals-new-quote-button}}
#   {{shot: deals-new-quote-button "The New Quote button on a deal"}}
class Knowledge::Screenshot < ApplicationRecord
  self.table_name = 'knowledge_screenshots'

  SIZES = %w[desktop mobile].freeze
  STATUSES = %w[pending ok broken].freeze
  KEY_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  # A shot line in an article body, Markdown or editor HTML.
  LINE = /\{\{\s*shot:\s*([a-z0-9-]+)(?:\s+"([^"]*)")?\s*\}\}/
  # More than this share of the picture changed: the article text may be out of date.
  REVIEW_THRESHOLD = 0.15

  validates :key, presence: true, uniqueness: true, format: { with: KEY_FORMAT, message: 'is lowercase words joined by dashes' }
  validates :route, presence: true
  SIZES.each { |size| validates :"#{size}_status", inclusion: { in: STATUSES } }

  scope :ordered, -> { order(:module_key, :key) }

  # The keys an article body shows, in order.
  def self.keys_in(text)
    text.to_s.scan(LINE).map(&:first).uniq
  end

  # An article body without its shot lines, for search and the AI assistant.
  def self.strip(text)
    text.to_s.gsub(LINE, '').gsub(/\n{3,}/, "\n\n")
  end

  # The articles that show this shot.
  def articles
    Knowledge::Article.where('content LIKE ?', "%shot:%#{self.class.sanitize_sql_like(key)}%").select { |a| self.class.keys_in(a.content).include?(key) }
  end

  # What an article needs to draw the shots it names, by key. Dealers get
  # only shots with a picture; a platform admin also gets the broken and
  # waiting ones, so the article can say what is wrong where the shot belongs.
  def self.for_article(text, admin: false)
    keys = keys_in(text)
    return {} if keys.empty?

    where(key: keys).each_with_object({}) do |shot, out|
      json = shot.as_article_json
      next unless admin || json[:desktop_url] || json[:mobile_url]

      out[shot.key] = admin ? json.merge(admin_note: shot.admin_note) : json
    end
  end

  # A size's picture, only when the last run found it.
  def picture(size)
    send("#{size}_status") == 'ok' && send("#{size}_url").presence || nil
  end

  def as_article_json
    desktop = picture('desktop')
    mobile = picture('mobile')
    { alt: alt_text.presence || title.to_s, desktop_url: desktop || mobile, mobile_url: mobile,
      desktop_width: desktop ? desktop_width : mobile_width, desktop_height: desktop ? desktop_height : mobile_height }
  end

  # Why a shot is not showing (or half showing), for platform admins.
  def admin_note
    problems = SIZES.filter_map do |size|
      case send("#{size}_status")
      when 'broken' then "#{size}: #{send("#{size}_error").presence || 'not found'}"
      when 'pending' then "#{size}: not taken yet (the next morning's run takes it)"
      end
    end
    problems.empty? ? nil : "Screenshot #{key}: #{problems.join('; ')}"
  end

  def as_api_json
    {
      id: id, key: key, module_key: module_key, title: title, alt_text: alt_text, route: route, steps: steps,
      crop_marker: crop_marker, padding: padding, mobile_steps: mobile_steps, mobile_crop_marker: mobile_crop_marker,
      mask_selectors: mask_selectors, source: source, captured_at: captured_at, commit_sha: commit_sha,
      needs_review: needs_review, changed_at: changed_at, updated_at: updated_at,
      **SIZES.to_h do |size|
        [size.to_sym, { url: send("#{size}_url"), previous_url: send("#{size}_previous_url"), status: send("#{size}_status"),
                        error: send("#{size}_error"), change_score: send("#{size}_change_score"),
                        width: send("#{size}_width"), height: send("#{size}_height") }]
      end
    }
  end

  # What the capture script needs to take it.
  def as_recipe_json
    {
      key: key, route: route, steps: steps, crop_marker: crop_marker, padding: padding,
      mobile_steps: mobile_steps, mobile_crop_marker: mobile_crop_marker, mask_selectors: mask_selectors,
      desktop_url: desktop_url, mobile_url: mobile_url
    }
  end

  # The nightly run's result for one size. A broken run keeps the old picture
  # (dealers stop seeing it until it is found again); a new picture replaces
  # the old one, and a big change flags the articles that show it.
  def record_capture!(size:, status:, url: nil, width: nil, height: nil, change_score: nil, error: nil,
                      commit_sha: nil, commit_at: nil)
    raise ArgumentError, "size must be #{SIZES.join(' or ')}" unless SIZES.include?(size)

    attrs = { "#{size}_status" => status, "#{size}_error" => (status == 'broken' ? error.to_s.first(500) : nil), captured_at: Time.current }
    if url.present?
      attrs.merge!("#{size}_previous_url" => send("#{size}_url"), "#{size}_url" => url, "#{size}_width" => width,
                   "#{size}_height" => height, "#{size}_change_score" => change_score, commit_sha: commit_sha, commit_at: commit_at)
      big = send("#{size}_url").present? && change_score.to_f > REVIEW_THRESHOLD
      attrs.merge!(needs_review: true, changed_at: Time.current) if big
    end
    update!(attrs)
  end
end
