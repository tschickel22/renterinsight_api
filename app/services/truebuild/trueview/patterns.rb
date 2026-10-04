# frozen_string_literal: true

module Truebuild
  module Trueview
    # Looks across a run's held-back drawings for a cause none of them can
    # fix alone. Each drawing's check only judges that drawing, so a bad
    # outline was paid for once per color: Aspire 082's bath held back five
    # of six countertops because the cabinets had taken the counter's front
    # edge, and every redraw failed the same way.
    #
    # Where several colors of one surface on one photo are held back, Claude
    # sees the photo, the outline and every complaint together and names the
    # cause. An outline at fault is outlined again with what was wrong, and
    # its drawings are cut again for the price of the check, not redrawn.
    # Any other cause (the drawing model cannot do it, a wrong sample, a
    # photo it cannot work with) is recorded for the lab and the run's
    # notice, so nobody keeps paying to redraw it.
    module Patterns
      module_function

      MIN_HELD = 3 # colors of one surface held back on one photo before it is a pattern
      MIN_SHARE = 0.5 # and at least this share of that surface's colors there

      TOOL = {
        name: 'diagnose_pattern',
        description: 'Name the common cause of several held-back renderings of one surface in one photo.',
        input_schema: {
          type: 'object',
          properties: {
            cause: { type: 'string', enum: %w[outline drawing sample photo mixed],
                     description: 'outline: the magenta outline covers the wrong area or misses part of the surface, so ' \
                                  'every color fails the same way; drawing: the image model cannot render this finish or ' \
                                  'item well; sample: the finish is judged against the wrong sample; photo: the photo itself ' \
                                  'makes the surface unworkable; mixed: no single cause.' },
            outline_note: { type: 'string', description: 'If the outline is at fault: what it should cover or leave out, in one ' \
                                                        'or two sentences, for the next outline.' },
            summary: { type: 'string', description: 'One sentence for the admin: what is wrong and why.' }
          },
          required: %w[cause summary]
        }
      }.freeze

      # => [{ 'photo', 'surface', 'held', 'of', 'cause', 'summary', 'action' }]
      def review!(run)
        rows = run.renders.where(status: %w[rejected done]).to_a.select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
        groups = rows.group_by { |r| [r.source_url, Surfaces.category(r.selection.first&.dig('surface'))] }
        found = groups.filter_map do |(photo, key), rs|
          held = rs.select { |r| r.status == 'rejected' }
          next if key.nil? || held.size < MIN_HELD || held.size < rs.size * MIN_SHARE

          mask = TruebuildSurfaceMask.find_by(source_url: photo, surface: key, version: Surfaces::VERSION)
          next unless mask&.present?
          next if mask.usage['pattern_redo'] # its outline was already redone for a pattern once

          diagnose!(mask, held).merge('photo' => photo, 'surface' => key, 'held' => held.size, 'of' => rs.size)
        rescue StandardError => e
          Rails.logger.warn("TrueView patterns #{photo} #{key}: #{e.message}")
          nil
        end
        run.reload.update!(progress: run.progress.merge('patterns' => Array(run.progress['patterns']) + found)) if found.any?
        found
      end

      def diagnose!(mask, held)
        source = Trueview.fetch_source(mask.source_url)
        photo = Surfaces.rgb(Vips::Image.new_from_buffer(source[:bytes], ''))
        outline = Vips::Image.new_from_buffer(Trueview.fetch_source(mask.mask_url)[:bytes], '')
        outline = outline.extract_band(0) if outline.bands > 1
        outline = Layer.fit(outline, photo.width, photo.height)
        tinted = (outline > 127).ifthenelse((photo * 0.4 + [153, 0, 153]).cast(:uchar), photo).cast(:uchar).copy(interpretation: :srgb)
        complaints = held.map { |r| "- #{r.selection.first&.dig('value')}: #{r.usage.dig('check', 'note') || r.error}" }.uniq.first(12)
        result = Catalog::PriceBooks::ClaudeClient.call(
          system: 'You review a home configurator\'s renderings. Several colors of one surface were all rejected on the ' \
                  'same photo; find what they have in common.',
          tool: TOOL, max_tokens: 500, temperature: 0,
          content: [{ type: 'text', text: 'The photo:' }, LayerCheck.image(photo),
                    { type: 'text', text: "The outline every #{mask.surface} rendering is cut to, in magenta. It should be: " \
                                          "#{Surfaces.describe(mask.surface)}." },
                    LayerCheck.image(tinted),
                    { type: 'text', text: "Why each color was rejected:\n#{complaints.join("\n")}" }]
        )
        input = result[:input]
        action = if input['cause'] == 'outline' && input['outline_note'].present?
                   redo!(mask, input['outline_note'])
                   'outlined again; its drawings are cut again'
                 else
                   'left for review'
                 end
        { 'cause' => input['cause'], 'summary' => input['summary'].to_s.first(300), 'action' => action,
          'cost_usd' => Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens]).round(4) }
      end

      # Outlined again in the background, told what was wrong; Surfaces.redo!
      # then cuts the surface's drawings again, held-back ones included.
      def redo!(mask, note)
        # redo_pending: its held-back drawings wait for the redo to cut them
        # again, rather than being redrawn meanwhile (Buyer.held_before_escalation).
        mask.update_columns(usage: mask.usage.merge('pattern_redo' => true, 'redo_pending' => true), updated_at: Time.current)
        TruebuildOutlineRedoJob.perform_later(mask.id, note)
      end
    end
  end
end
