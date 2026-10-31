# frozen_string_literal: true

module Guide
  # Production copies help article screenshots and article edits from
  # staging (backlog E89); Guide::ApprovedHelpSync calls this with what
  # staging sent. Production never takes a picture itself.
  #
  # A picture is copied into production's own bucket only once production's
  # build has caught up with the one it was taken on (its commit is in a
  # production build, or production's build is newer) and has the marker it
  # is cropped to. Until then production keeps the picture it has, so a
  # dealer never sees a screen they don't have yet.
  class ScreenshotSync
    RECIPE_FIELDS = %w[module_key title alt_text route steps crop_marker padding mobile_steps mobile_crop_marker mask_selectors].freeze

    def initialize(known_markers:, production_commits:, production_built_at:, downloader: nil)
      @known = known_markers
      @commits = production_commits.to_set
      @built_at = production_built_at
      # The same streamed download training videos use.
      @downloader = downloader || Guide::TrainingVideoSync.new.method(:download)
    end

    # remote: staging's screenshots (GuideSyncController#screenshots). Returns how many pictures were copied.
    def apply(remote)
      Array(remote).sum { |r| apply_one(r) }
    end

    # remote: articles edited on staging since the last copy. Only articles
    # production already has are updated; a new one arrives the usual way
    # (the release queue or a loader), once production has the feature.
    def apply_articles(remote)
      Array(remote).count do |r|
        article = Knowledge::Article.find_by(slug: r['slug'])
        next false unless article

        attrs = r.slice('title', 'excerpt', 'content', 'is_published')
        next false if attrs.all? { |k, v| article.send(k) == v }

        article.update!(attrs)
        true
      end
    end

    private

    def apply_one(r)
      shot = Knowledge::Screenshot.find_or_initialize_by(key: r['key'])
      shot.assign_attributes(r.slice(*RECIPE_FIELDS).merge('source' => 'staging'))
      shot.save!
      return 0 unless ready?(r)

      source = shot.source_files || {}
      copied = Knowledge::Screenshot::SIZES.count do |size|
        url = r.dig(size, 'url')
        next false if url.blank? || r.dig(size, 'status') != 'ok' || source[size] == url

        stored = copy_picture(shot, size, url)
        next false unless stored

        shot.update!("#{size}_url" => stored[:url], "#{size}_status" => 'ok', "#{size}_error" => nil,
                     "#{size}_width" => r.dig(size, 'width'), "#{size}_height" => r.dig(size, 'height'))
        source[size] = url
        true
      end
      shot.update_columns(source_files: source, commit_sha: r['commit_sha'], captured_at: r['captured_at']) if copied.positive?
      copied
    rescue StandardError => e
      Rails.logger.warn("[Guide::ScreenshotSync] #{r['key']}: #{e.class} #{e.message}")
      0
    end

    def ready?(r)
      # "css:main" is a page region every build has; only data-tour markers are checked.
      markers = [r['crop_marker'], r['mobile_crop_marker']].compact_blank.reject { |m| m.start_with?('css:') }
      return false unless markers.all? { |m| @known.include?(m) }
      return true if r['commit_sha'].blank? || @commits.include?(r['commit_sha'])

      taken_on = Time.zone.parse(r['commit_at'].to_s) rescue nil
      taken_on.present? && @built_at.present? && @built_at >= taken_on
    end

    def copy_picture(shot, size, url)
      Tempfile.create(['help-screenshot', '.png'], binmode: true) do |tmp|
        return nil unless @downloader.call(url, tmp)

        tmp.flush
        file = Guide::TrainingVideoSync::Upload.new(tmp.path, "#{shot.key}-#{size}.png", 'image/png')
        S3UploadService.new.upload(file, key: "help-screenshots/#{shot.key}-#{size}-#{Time.current.to_i}.png")
      end
    end
  end
end
