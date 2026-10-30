# frozen_string_literal: true

# A training video in the help center's Videos tab (E88). Platform content,
# not tenant data: no company_id. Dealers see a video only when it is
# published and the tab is switched on (TrainingVideo.enabled?); the public
# watch page (/watch/:share_token) works whenever sharing is on, so a video
# can be sent round before the tab opens.
class TrainingVideo < ApplicationRecord
  SETTING_KEY = 'training_videos_enabled'

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
    json.merge!(share_token: share_token, share_enabled: share_enabled, video_size: video_size) if admin
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
