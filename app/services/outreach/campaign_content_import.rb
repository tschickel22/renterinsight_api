# frozen_string_literal: true

module Outreach
  # Finds the videos in a company's running campaigns and lists them for review
  # (backlog E105). New items wait for approval, and anything already in the
  # library is left exactly as it is.
  class CampaignContentImport
    VIDEO_URL = %r{https?://(?:www\.)?(?:vimeo\.com/\d+(?:/[0-9a-f]+)?|youtube\.com/watch\?v=[\w-]+|youtu\.be/[\w-]+)}i
    MERGE_TAG = /\{\{.*?\}\}/

    Result = Struct.new(:found, :added, keyword_init: true)

    def self.call(company)
      new(company).call
    end

    def initialize(company)
      @company = company
    end

    def call
      found = videos
      existing = @company.outreach_content_items.where(url: found.keys).pluck(:url)
      added = 0
      found.except(*existing).each_value do |attrs|
        added += 1 if @company.outreach_content_items.build(attrs).save
      end
      Result.new(found: found.size, added: added)
    end

    private

    # { url => attributes }. Email steps go first because their subject makes
    # the best title.
    def videos
      steps = CampaignStep.active.where(campaign_id: @company.campaigns.running.select(:id)).order(:campaign_id, :position).to_a
      steps.sort_by { |step| step.sms_channel? ? 1 : 0 }.each_with_object({}) do |step, out|
        urls_in(step).each do |url|
          out[url] ||= { title: title_for(step), url: url, description: description_for(step, url),
                         source_kind: 'campaign', source_campaign_id: step.campaign_id, source_step_id: step.id,
                         status: 'pending' }
        end
      end
    end

    def urls_in(step)
      "#{JSON.generate(step.body_blocks || [])} #{step.sms_body}".scan(VIDEO_URL).uniq
    end

    def title_for(step)
      subject = step.subject.to_s.gsub(MERGE_TAG, '').squish
      return subject.truncate(120) if subject.present?

      alt = blocks(step).filter_map { |b| b['alt'].presence }.first
      (alt || 'Video from a campaign text').to_s.squish.truncate(120)
    end

    def description_for(step, url)
      text = blocks(step).filter_map { |b| b['html'] if b['type'] == 'text' }.join(' ')
      text = step.sms_body.to_s if text.blank?
      plain = ActionController::Base.helpers.strip_tags(text).gsub(MERGE_TAG, '').gsub(url, '')
      plain.sub(/Reply STOP.*\z/im, '').squish.sub(/\AHi\s*,\s*/i, '').truncate(300).presence
    end

    def blocks(step)
      Array(step.body_blocks).select { |b| b.is_a?(Hash) }.map(&:stringify_keys)
    end
  end
end
