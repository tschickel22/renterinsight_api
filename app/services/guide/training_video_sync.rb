# frozen_string_literal: true

require 'net/http'

module Guide
  # Production copies the training videos made on staging (E88), the same
  # way it copies approved tours (Guide::ApprovedHelpSync calls this with
  # staging's list). A video is matched across servers by its uid. Words,
  # chapters, order and publish state follow staging; the MP4, poster and
  # captions are copied into production's own bucket, only when they changed
  # on staging. The help center switch stays each server's own.
  class TrainingVideoSync
    FIELDS = %w[title description module_key position duration_seconds chapters transcript is_published share_enabled covers].freeze
    FILES = { 'video' => 'video_url', 'poster' => 'poster_url', 'captions' => 'captions_url' }.freeze

    def initialize(downloader: method(:download))
      @downloader = downloader
    end

    # remote: staging's videos (GuideSyncController#videos). Returns how many changed.
    def apply(remote)
      remote = Array(remote)
      changed = remote.count { |r| apply_one(r) }
      # Deleted on staging: hidden here, not deleted, in case people were told to watch it.
      TrainingVideo.where.not(source_files: {}).where.not(uid: remote.map { |r| r['uid'] }).where(is_published: true)
                   .update_all(is_published: false, updated_at: Time.current)
      changed
    end

    private

    def apply_one(r)
      video = TrainingVideo.find_or_initialize_by(uid: r['uid'])
      source = video.source_files || {}
      return false if video.persisted? && source['updated_at'] == r['updated_at']

      video.assign_attributes(r.slice(*FIELDS))
      video.title = r['title']
      video.slug = r['slug'] if r['slug'].present? && !TrainingVideo.where.not(id: video.id).exists?(slug: r['slug'])
      video.share_token = r['share_token'] if video.new_record? && r['share_token'].present? &&
                                             !TrainingVideo.exists?(share_token: r['share_token'])
      video.save!
      FILES.each do |kind, column|
        url = r[column]
        next if url.blank? || source[kind] == url

        stored = copy_file(video, kind, url)
        next unless stored

        video.update!(column => stored[:url], **(kind == 'video' ? { video_key: stored[:key], video_size: stored[:size] } : {}))
        source[kind] = url
      end
      video.update_columns(source_files: source.merge('updated_at' => r['updated_at']))
      true
    rescue StandardError => e
      Rails.logger.warn("[Guide::TrainingVideoSync] #{r['uid']}: #{e.class} #{e.message}")
      false
    end

    # Streamed through a temp file, never held in memory.
    def copy_file(video, kind, url)
      ext = File.extname(URI(url).path).downcase
      Tempfile.create(['training-video', ext], binmode: true) do |tmp|
        return nil unless @downloader.call(url, tmp)

        tmp.flush
        file = Upload.new(tmp.path, File.basename(URI(url).path), content_type_for(ext))
        S3UploadService.new.upload(file, key: "training-videos/#{video.slug}-#{Time.current.to_i}#{ext}")
      end
    end

    def download(url, io)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 120) do |http|
        http.request_get(uri.request_uri) do |response|
          return false unless response.is_a?(Net::HTTPSuccess)

          response.read_body { |chunk| io.write(chunk) }
        end
      end
      true
    end

    def content_type_for(ext)
      { '.mp4' => 'video/mp4', '.vtt' => 'text/vtt', '.png' => 'image/png', '.webp' => 'image/webp' }[ext] || 'image/jpeg'
    end

    # What S3UploadService needs of a file.
    Upload = Struct.new(:path, :original_filename, :content_type)
  end
end
