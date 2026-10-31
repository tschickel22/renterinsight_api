# frozen_string_literal: true

module Guide
  # Loads the screenshot recipes kept in code (db/guide/screenshots.yml,
  # backlog E89) and puts each shot into the articles it lists.
  #
  # Runs on the server that takes the pictures (staging), when the capture
  # script asks for its recipes and the file has changed since the last
  # load, so a deploy is all it takes. Production never loads it: it copies
  # shots and articles from staging (Guide::ScreenshotSync).
  #
  # The file wins for the recipes it names; recipes made in Knowledge admin
  # are left alone. A shot line is added to an article only when the article
  # does not show that shot yet, so moving or deleting the line in Knowledge
  # admin sticks.
  class ScreenshotLoader
    PATH = Rails.root.join('db/guide/screenshots.yml')
    DIGEST = 'guide_screenshots_digest'
    RECIPE_FIELDS = {
      'module' => :module_key, 'title' => :title, 'alt' => :alt_text, 'route' => :route, 'steps' => :steps,
      'crop' => :crop_marker, 'padding' => :padding, 'mobile_steps' => :mobile_steps,
      'mobile_crop' => :mobile_crop_marker, 'mask' => :mask_selectors
    }.freeze

    Result = Struct.new(:recipes, :placed, :problems, keyword_init: true)

    def self.load_if_changed!(path = PATH)
      return nil unless File.exist?(path)

      digest = Digest::SHA256.file(path).hexdigest
      return nil if Setting.get('Platform', 0, DIGEST, nil) == digest

      result = new(YAML.safe_load_file(path)).load!
      Setting.set('Platform', 0, DIGEST, digest)
      Rails.logger.info("[Guide::ScreenshotLoader] #{result.recipes} recipes, #{result.placed.size} placed, problems: #{result.problems.inspect}")
      result
    end

    def initialize(data)
      @data = data || {}
    end

    def load!
      result = Result.new(recipes: 0, placed: [], problems: [])
      Array(@data['screenshots']).each do |entry|
        shot = upsert(entry, result)
        next unless shot

        result.recipes += 1
        Array(entry['articles']).each { |placement| place(shot, placement, result) }
      end
      result
    end

    private

    def upsert(entry, result)
      shot = Knowledge::Screenshot.find_or_initialize_by(key: entry['key'].to_s)
      attrs = RECIPE_FIELDS.each_with_object({}) { |(from, to), h| h[to] = entry[from] if entry.key?(from) }
      attrs[:steps] ||= []
      attrs[:mask_selectors] ||= []
      shot.assign_attributes(attrs.merge(source: 'file'))
      shot.save!
      shot
    rescue ActiveRecord::RecordInvalid => e
      result.problems << "#{entry['key']}: #{e.record.errors.full_messages.to_sentence}"
      nil
    end

    def place(shot, placement, result)
      article = Knowledge::Article.find_by(slug: placement['slug'])
      return result.problems << "#{shot.key}: no article #{placement['slug']}" unless article
      return if Knowledge::Screenshot.keys_in(article.content).include?(shot.key)

      content = self.class.insert(article.content.to_s, shot_line(shot, placement['caption']), after: placement['after'])
      return result.problems << "#{shot.key}: #{placement['slug']} is HTML; add the line in Knowledge admin" unless content

      article.update!(content: content)
      result.placed << "#{shot.key} -> #{article.slug}"
    end

    def shot_line(shot, caption)
      caption.present? ? %({{shot: #{shot.key} "#{caption.to_s.delete('"')}"}}) : "{{shot: #{shot.key}}}"
    end

    # The body with the line after the paragraph (or list) that follows the
    # heading named in `after`; after the first paragraph when there is no
    # such heading. nil for an editor-HTML body.
    def self.insert(body, line, after: nil)
      return nil if body.match?(/<(p|h[1-6]|ul|ol|li|div)\b[^>]*>/i)

      lines = body.gsub("\r\n", "\n").split("\n", -1)
      start = after.present? ? lines.index { |l| l.strip.casecmp?(after.to_s.strip) } : nil
      i = skip_block(lines, start ? start + 1 : first_block_start(lines))
      lines.insert(i, '', line)
      lines.join("\n").gsub(/\n{3,}/, "\n\n")
    end

    # Index of the line after the first block of text at or after `from`.
    def self.skip_block(lines, from)
      i = from
      i += 1 while i < lines.size && lines[i].strip.empty?
      i += 1 while i < lines.size && lines[i].strip.present? && !lines[i].start_with?('#')
      i
    end

    # The first paragraph that is not a heading.
    def self.first_block_start(lines)
      i = 0
      i += 1 while i < lines.size && (lines[i].strip.empty? || lines[i].start_with?('#'))
      i
    end
  end
end
