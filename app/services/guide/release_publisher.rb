# frozen_string_literal: true

module Guide
  # Turns an approved change-queue item's drafts into live help: an article, a
  # "show me where" tour and a What's New note (Knowledge::Article with
  # article_type release_note). Approving again updates what it made before
  # rather than making duplicates.
  class ReleasePublisher
    def initialize(item, user)
      @item = item
      @user = user
      @drafts = item.drafts || {}
    end

    def publish!
      Knowledge::ChangeQueueItem.transaction do
        case @item.entity_type
        when 'atlas_entry' then publish_entry unless @item.change_type == 'removed'
        when 'gap'         then publish_entry
        when 'release'     then publish_release
        end
        @item.update!(status: 'approved', reviewed_by: @user, reviewed_at: Time.current, published_at: Time.current)
      end
      @item
    end

    private

    def entry
      @item.new_value || {}
    end

    def publish_entry
      article = @drafts['article'] || {}
      if article['title'].present? && article['content'].present?
        content = with_screenshot(article['content'], @drafts['screenshot'])
        record = upsert_article(@item.published_article_id, article['title'], article['excerpt'], content, 'how_to')
        @item.published_article_id = record.id
      end

      return if @item.entity_type == 'gap'

      steps = Array(@drafts.dig('tour', 'steps'))
      if steps.any?
        @item.published_tour_id = upsert_tour(steps).id
      end

      if @drafts['whats_new'].present?
        note = upsert_article(@item.published_note_id, "New: #{entry['title']}", @drafts['whats_new'].first(240),
                              @drafts['whats_new'], 'release_note', slug_prefix: "whats-new-#{Date.current}")
        @item.published_note_id = note.id
      end
    end

    def publish_release
      return unless @drafts['user_facing'] && @drafts['notes'].present?

      note = upsert_article(@item.published_note_id, @drafts['title'].presence || "What's new", @drafts['notes'].lines.first.to_s.first(240),
                            @drafts['notes'], 'release_note', slug_prefix: "release-#{Date.current}")
      @item.published_note_id = note.id
    end

    # The article with the screenshot the drafter asked for (E89): its recipe
    # is made here and the nightly run on staging takes the pictures.
    def with_screenshot(content, shot)
      return content unless shot.is_a?(Hash) && shot['key'].to_s.match?(Knowledge::Screenshot::KEY_FORMAT)
      return content if Knowledge::Screenshot.keys_in(content).include?(shot['key'])

      Knowledge::Screenshot.find_or_create_by!(key: shot['key']) do |s|
        s.assign_attributes(route: shot['route'], crop_marker: shot['crop_marker'], module_key: entry['module'].presence,
                            title: shot['caption'], alt_text: shot['caption'], source: 'drafted')
      end
      line = shot['caption'].present? ? %({{shot: #{shot['key']} "#{shot['caption']}"}}) : "{{shot: #{shot['key']}}}"
      Guide::ScreenshotLoader.insert(content, line) || content
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Guide::ReleasePublisher] screenshot #{shot['key']}: #{e.message}")
      content
    end

    def upsert_article(id, title, excerpt, content, type, slug_prefix: nil)
      record = id && Knowledge::Article.find_by(id: id)
      record ||= Knowledge::Article.new(slug: unique_slug([slug_prefix, title].compact.join('-')))
      record.assign_attributes(title: title, excerpt: excerpt, content: content, article_type: type, is_published: true)
      record.save!
      record
    end

    def unique_slug(base)
      slug = base.to_s.parameterize.first(90).presence || "help-#{SecureRandom.hex(3)}"
      candidate = slug
      n = 1
      candidate = "#{slug}-#{n += 1}" while Knowledge::Article.exists?(slug: candidate)
      candidate
    end

    def upsert_tour(steps)
      tour = (@item.published_tour_id && Tour.find_by(id: @item.published_tour_id)) ||
             Tour.find_or_initialize_by(key: "where-#{entry['key'].to_s.parameterize}")
      tour.assign_attributes(
        name: @drafts.dig('tour', 'name').presence || "Where to find #{entry['title']}",
        description: @drafts.dig('article', 'excerpt'),
        trigger_type: 'manual', is_active: true,
        # New steps reach dealers only after a person plays and approves them.
        approved_at: nil, approved_by_id: nil
      )
      tour.save!
      tour.steps.destroy_all
      steps.each_with_index do |s, i|
        tour.steps.create!(
          position: i + 1, route: s['route'].presence, selector: s['selector'], title: s['title'], content: s['content'],
          placement: s['selector'].to_s.include?('"nav') ? 'right' : 'bottom',
          highlight_type: 'outline', click_required: s['click_required'] == true, input_required: false
        )
      end
      tour
    end
  end
end
