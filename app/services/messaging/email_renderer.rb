module Messaging
  class EmailRenderer
    def initialize(step:, recipient:, campaign:, campaign_send:, company:, base_url:)
      @step = step
      @recipient = recipient
      @campaign = campaign
      @send = campaign_send
      @company = company
      @base_url = base_url
    end

    def render
      urls = build_urls
      context = MergeTagResolver.build_context(
        recipient: @recipient, company: @company, rep: @campaign.try(:created_by),
        campaign_send: @send, urls: urls
      )
      MergeTagResolver.enrich_context(context, recipient: @recipient, company: @company)

      inventory_units = nil
      blocks = Array(@step.body_blocks)
      inventory_block = blocks.find { |b| b.is_a?(Hash) && (b['type'] == 'inventory' || b[:type] == 'inventory') }

      # AI-authored plans put the config on the STEP column and produce a
      # body_blocks list of just text + footer — no marker block. Manual
      # CampaignBuilder puts the config on the block itself. Support both
      # by synthesizing a marker inside body_blocks (just before the
      # unsubscribe footer, or at the end) whenever the step column has a
      # config and body_blocks lacks a marker. The step-column config
      # remains the source of truth via the existing precedence below.
      step_config = @step.try(:inventory_block_config)
      if inventory_block.nil? && step_config.is_a?(Hash) && step_config.any?
        synthetic = { 'type' => 'inventory' }
        footer_idx = blocks.index { |b| b.is_a?(Hash) && (b['type'] == 'footer_unsubscribe' || b[:type] == 'footer_unsubscribe') }
        blocks = if footer_idx
                   blocks[0...footer_idx] + [synthetic] + blocks[footer_idx..]
                 else
                   blocks + [synthetic]
                 end
        inventory_block = synthetic
      end

      if inventory_block
        config = @step.try(:inventory_block_config).presence || inventory_block
        result = InventoryBlockResolver.new(
          config: config, recipient: @recipient, company: @company, base_url: @base_url
        ).resolve

        case result[:fallback_action]
        when :abort_send
          return { error: 'inventory_empty_abort' }
        when :show_cta
          inventory_units = []
          blocks = blocks.map do |b|
            if b.is_a?(Hash) && (b['type'] == 'inventory' || b[:type] == 'inventory')
              { 'type' => 'button', 'text' => 'View all available homes', 'href' => urls[:public_inventory_url] || '#' }
            else
              b
            end
          end
        when :skip_block
          inventory_units = []
          blocks = blocks.reject { |b| b.is_a?(Hash) && (b['type'] == 'inventory' || b[:type] == 'inventory') }
        else
          inventory_units = result[:units]
        end
      end

      subject = MergeTagResolver.resolve(@step.subject || @campaign.try(:subject_default), context)

      raw_html = BlockRenderer.new(
        blocks: blocks, context: context, company: @company,
        unsubscribe_url: urls[:unsubscribe_url], inventory_units: inventory_units
      ).render

      # Process step attachments only on real sends (skip on preview where @send is unsaved).
      # Tracked links appended to body, inline files returned for delivery.
      tracked_link_records, inline_uploads, attachment_metadata =
        if @send && @send.persisted?
          process_step_attachments
        else
          [[], [], []]
        end
      raw_html = append_tracked_link_section(raw_html, tracked_link_records) if tracked_link_records.any?

      tokenized = if @send && @send.persisted?
                    LinkTokenizer.new(campaign_send: @send, base_url: @base_url).tokenize_html(raw_html)
                  else
                    raw_html
                  end

      {
        subject: subject,
        html_body: tokenized,
        inline_attachments: inline_uploads,
        tracked_link_records: tracked_link_records,
        attachment_metadata: attachment_metadata,
        error: nil
      }
    end

    private

    def build_urls
      unsub = if @send && @send.persisted?
                token = Rails.application.message_verifier(:campaign_unsubscribe).generate({ 's' => @send.id })
                "#{@base_url.to_s.chomp('/')}/u/#{token}"
              else
                "#{@base_url.to_s.chomp('/')}/u/preview"
              end
      {
        unsubscribe_url: unsub,
        public_inventory_url: public_inventory_url,
        view_in_browser_url: nil
      }
    end

    def public_inventory_url
      return nil unless @company.respond_to?(:public_inventory_token) && @company.public_inventory_token.present?
      "#{@base_url.to_s.chomp('/')}/public/inventory/#{@company.public_inventory_token}"
    end

    # ---- Attachment handling for campaign emails ----
    # Mirrors ProcessNurtureStepJob#process_step_attachments.
    # Returns [tracked_link_records, inline_uploads, attachment_metadata].
    def process_step_attachments
      tracked_link_records = []
      inline_uploads       = []
      metadata             = []

      attachments = Array(@step.try(:attachments))
      return [tracked_link_records, inline_uploads, metadata] if attachments.empty?

      entity = @recipient.is_a?(ActiveRecord::Base) ? @recipient : nil

      attachments.each do |att|
        att = att.is_a?(Hash) ? att.deep_stringify_keys : {}
        filename      = att['filename']
        s3_key        = att['s3_key']
        content_type  = att['content_type']
        file_size     = att['size']
        delivery_mode = att['delivery_mode'].presence || 'tracked_link'

        next if s3_key.blank? || filename.blank?

        if delivery_mode == 'inline_attachment'
          uploaded = download_s3_object_as_upload(s3_key: s3_key, filename: filename, content_type: content_type)
          if uploaded
            inline_uploads << uploaded
            metadata << {
              'filename'      => filename,
              'delivery_mode' => 'inline_attachment',
              's3_key'        => s3_key
            }
          else
            Rails.logger.error "[Campaign] Skipping inline attachment #{filename} (#{s3_key}) — download failed"
          end
        else
          tl = TrackedLink.create_for_attachment!(
            company:      @company,
            s3_key:       s3_key,
            filename:     filename,
            content_type: content_type,
            file_size:    file_size,
            entity_type:  entity&.class&.name,
            entity_id:    entity&.id,
            source_type:  'CampaignStep',
            source_id:    @step.id
          )
          tracked_link_records << tl
          metadata << {
            'filename'        => filename,
            'delivery_mode'   => 'tracked_link',
            's3_key'          => s3_key,
            'tracked_link_id' => tl.id,
            'tracking_url'    => tl.tracking_url
          }
        end
      rescue => e
        Rails.logger.error "[Campaign] Attachment processing error (#{filename}): #{e.message}"
      end

      [tracked_link_records, inline_uploads, metadata]
    end

    def append_tracked_link_section(body, tracked_links)
      return body if tracked_links.empty?

      section = tracked_links.map do |tl|
        safe_filename = ERB::Util.html_escape(tl.filename.to_s)
        "<p><a href=\"#{tl.tracking_url}\">📎 #{safe_filename}</a></p>"
      end.join("\n")

      "#{body}\n#{section}"
    end

    def download_s3_object_as_upload(s3_key:, filename:, content_type:)
      require 'aws-sdk-s3'
      s3 = Aws::S3::Client.new(
        region: ENV['AWS_REGION'] || 'us-west-2',
        access_key_id: ENV['AWS_ACCESS_KEY_ID'],
        secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
      )
      bucket = ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'

      tempfile = Tempfile.new(['campaign_att', File.extname(filename)])
      tempfile.binmode
      s3.get_object({ bucket: bucket, key: s3_key }) do |chunk|
        tempfile.write(chunk)
      end
      tempfile.rewind

      ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename,
        type:     content_type || 'application/octet-stream'
      )
    rescue => e
      Rails.logger.error "[Campaign] S3 download failed for #{s3_key}: #{e.message}"
      nil
    end
  end
end
