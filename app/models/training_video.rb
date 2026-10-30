# frozen_string_literal: true

# A training video in the help center's Videos tab (E88). Platform content,
# not tenant data: no company_id. Dealers see a video only when it is
# published and the tab is switched on (TrainingVideo.enabled?); the public
# watch page (/watch/:share_token) works whenever sharing is on, so a video
# can be sent round before the tab opens.
class TrainingVideo < ApplicationRecord
  SETTING_KEY = 'training_videos_enabled'

  has_many :views, class_name: 'TrainingVideoView', dependent: :delete_all
  has_many :assignments, class_name: 'TrainingAssignment', dependent: :delete_all

  validates :title, :slug, :share_token, presence: true
  validates :slug, :share_token, uniqueness: true

  before_validation :fill_slug, :fill_share_token

  scope :ordered, -> { order(:module_key, :position, :id) }
  scope :published, -> { where(is_published: true).where.not(video_url: [nil, '']) }

  # The Videos tab, for everyone who isn't a platform admin.
  def self.enabled?
    Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY) == true
  end

  def self.enabled=(value)
    Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, SETTING_KEY, value == true)
  end

  # What a person sees in the Videos tab: published videos while the tab is
  # on; a platform admin (not proxying) sees every video with a file.
  def self.visible(admin:)
    return where.not(video_url: [nil, '']) if admin

    enabled? ? published : none
  end

  # The best videos for a question, each with the moment that answers it: the
  # narration line or chapter that shares the most words with it.
  def self.search(query, scope: published, limit: 3)
    terms = query.to_s.downcase.scan(/[a-z0-9&]+/).reject { |w| w.length < 3 || Knowledge::SmartSearchService::STOP_WORDS.include?(w) }.uniq.first(6)
    return [] if terms.empty?

    scope.to_a.filter_map do |video|
      title = video.title.to_s.downcase
      body = [video.description, video.transcript, Array(video.chapters).map { |c| c['title'] }].flatten.compact.join(' ').downcase
      score = terms.sum { |t| (title.include?(t) ? 3 : 0) + (body.include?(t) ? 1 : 0) }
      next if score.zero?

      [video, score, video.moment_for(terms)]
    end.sort_by { |_, score, _| -score }.first(limit).map { |video, _, moment| [video, moment] }
  end

  # { start:, label: } for the chapter or narration line that best matches.
  def moment_for(terms)
    lines = transcript.to_s.lines.filter_map do |line|
      m = /\A(\d+):(\d{2}) (.+)\z/.match(line.strip)
      m && { start: m[1].to_i * 60 + m[2].to_i, text: m[3] }
    end
    best = lines.max_by { |l| terms.count { |t| l[:text].downcase.include?(t) } }
    best = nil if best && terms.none? { |t| best[:text].downcase.include?(t) }
    chapter = Array(chapters).select { |c| c['start'].to_i <= (best ? best[:start] : 0) }.max_by { |c| c['start'].to_i }
    chapter ||= Array(chapters).max_by { |c| terms.count { |t| c['title'].to_s.downcase.include?(t) } }
    { start: best ? [best[:start] - 1, 0].max : chapter&.dig('start').to_i, label: chapter&.dig('title') }
  end

  # Captions (.vtt) to narration, one "m:ss sentence" per line.
  def self.transcript_from_vtt(vtt)
    vtt.to_s.split(/\r?\n\r?\n/).filter_map do |cue|
      lines = cue.strip.lines.map(&:strip)
      at = lines.index { |l| l.include?('-->') }
      next unless at

      h, m, s = lines[at].split('-->').first.strip.split(':').map(&:to_f).then { |p| p.size == 2 ? [0, *p] : p }
      total = (h * 3600 + m * 60 + s).floor
      text = lines[(at + 1)..].join(' ').strip
      "#{total / 60}:#{format('%02d', total % 60)} #{text}" if text.present?
    end.join("\n")
  end

  def fill_transcript_from_url!
    response = Net::HTTP.get_response(URI(captions_url))
    update_columns(transcript: self.class.transcript_from_vtt(response.body.to_s.force_encoding('UTF-8'))) if response.is_a?(Net::HTTPSuccess)
  rescue StandardError => e
    Rails.logger.warn("[TrainingVideo] transcript for #{id}: #{e.class} #{e.message}")
  end

  def new_share_token!
    update!(share_token: self.class.generate_token)
  end

  def self.generate_token
    SecureRandom.urlsafe_base64(12)
  end

  def as_api_json(admin: false)
    json = {
      id: id, title: title, slug: slug, description: description, module_key: module_key,
      position: position, duration_seconds: duration_seconds, video_url: video_url,
      poster_url: poster_url, captions_url: captions_url, chapters: chapters,
      is_published: is_published, updated_at: updated_at
    }
    if admin
      json.merge!(share_token: share_token, share_enabled: share_enabled, video_size: video_size, covers: covers,
                  public_views: public_views, from_staging: source_files.present?)
    end
    json
  end

  # What the public watch page gets: nothing about publishing or the admin.
  def as_public_json
    { title: title, description: description, duration_seconds: duration_seconds, video_url: video_url,
      poster_url: poster_url, captions_url: captions_url, chapters: chapters }
  end

  private

  # A new video starts as "New training video"; its slug follows the title
  # until it's renamed, and never clashes with another video's.
  def fill_slug
    return if title.blank?
    return unless slug.blank? || (will_save_change_to_title? && slug.to_s.match?(/\Anew-training-video(-\d+)?\z/))

    base = title.parameterize.presence || 'training-video'
    candidate = base
    n = 1
    candidate = "#{base}-#{n += 1}" while self.class.where.not(id: id).exists?(slug: candidate)
    self.slug = candidate
  end

  def fill_share_token
    self.share_token = self.class.generate_token if share_token.blank?
  end
end
