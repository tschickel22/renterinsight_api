# frozen_string_literal: true

module Truebuild
  module Trueview
    # A factory run's checks done in a Claude Code session instead of through
    # Anthropic's API (backlog E80). Claude checks were 35 to 40% of TrueView's
    # drawing spend (2026-10-18); a session already paid for on Tom's plan can
    # look at the same images and judge them on the same rubric.
    #
    # A run started with checks: 'session' draws as usual. Where it would call
    # LayerCheck, the drawing (or a plain color laid on, Tint) is cut and saved
    # waiting for a verdict: still "running", so the run does not finish, and
    # marked awaiting_check. A session lists them (pending), judges each on the
    # photo, and hands back verdicts (apply!), which do what the API's verdict
    # would have: pass, draw again, or hold back for the run's end.
    #
    # Outline checks and photo picks still go through the API (phase 2).
    module SessionChecks
      module_function

      def session?(render)
        id = render.usage['factory_run_id'] or return false
        TruebuildFactoryRun.where(id: id).where("progress->>'checks' = 'session'").exists?
      end

      # kind: 'batch' (a drawing Google returned) or 'tint' (a color laid on).
      def await!(render, kind:, layer:, image: nil, usage: {})
        attrs = { status: 'running', layer_url: Trueview.store(render, layer[:bytes], layer[:mime], suffix: "#{kind}-layer"),
                  mask_coverage: layer[:coverage],
                  usage: render.usage.except('batch_drawn').merge(usage).merge('awaiting_check' => { 'kind' => kind, 'at' => Time.current.iso8601 }) }
        attrs[:image_url] = Trueview.store(render, image[:bytes], image[:mime], suffix: kind) if image
        render.update!(attrs)
      end

      def waiting(run = nil)
        rows = run ? run.renders : TruebuildRender.where(purpose: 'layer')
        rows.where(status: 'running').where("usage ? 'awaiting_check'")
      end

      # What a session needs to judge each one: the photo, the layer to lay
      # over it, the factory sample, and the rubric the API check is given.
      def pending(run = nil, limit: 200)
        waiting(run).order(:id).limit(limit).map do |r|
          surface = r.selection.first&.dig('surface')
          value = r.selection.first&.dig('value')
          swatch = CatalogSwatch.find_by(id: Array(r.usage['swatch_ids']).first)
          { id: r.id, kind: r.usage.dig('awaiting_check', 'kind'), photo_url: r.source_url, layer_url: r.layer_url,
            surface: surface, value: value, sample_url: swatch&.image_url, hex: swatch&.hex, rubric: rubric(surface, value, swatch) }
        end
      end

      def rubric(surface, value, swatch)
        "The photo with the #{surface} changed to #{value}. Is all of the visible #{surface} in the new finish, evenly, " \
          "with nothing else changed or added?#{LayerCheck.scope(surface, value)}#{LayerCheck.match_rule(swatch, swatch&.hex)} " \
          "Score #{LayerCheck::TOOL[:input_schema][:properties][:score][:description]}. Passes at #{LayerCheck::MIN_SCORE} or more."
      end

      # verdict: { 'score' => 1..5, 'note' => '...' }. => the row.
      def apply!(render, verdict)
        return render unless render.status == 'running' && render.usage['awaiting_check']

        score = verdict['score'].to_i
        check = { 'score' => score, 'note' => verdict['note'].to_s.strip.presence, 'ok' => score >= LayerCheck::MIN_SCORE, 'by' => 'session' }
        kind = render.usage.dig('awaiting_check', 'kind')
        usage = render.usage.except('awaiting_check')
        kind == 'tint' ? tint_verdict(render, check, usage) : drawing_verdict(render, check, usage)
        run = TruebuildFactoryRun.find_by(id: render.usage['factory_run_id'])
        FactoryRun.drawing_finished!(run) if run
        render
      end

      def tint_verdict(render, check, usage)
        if check['ok']
          render.update!(status: 'done', model: 'tint', latency_ms: 0,
                         usage: usage.merge('tinted' => true, 'mask_version' => Layer::VERSION, 'check' => check, 'outlined' => true))
        else
          # Drawn instead, in the run's next batch, as a failed API check would.
          render.update!(status: 'queued', layer_url: nil, image_url: nil,
                         usage: usage.merge('tint_failed' => true, 'tint_note' => check['note']).compact)
        end
      end

      def drawing_verdict(render, check, usage)
        tries = usage['tries'].to_i + 1
        notes = Array(usage['notes']) + [check['note']].compact
        render.usage = usage
        if !check['ok'] && tries < Batch.limit(render) && !HeldSummary.shown_anyway?(render, check)
          return Batch.again(render, tries, notes, nil)
        end

        attrs = { status: check['ok'] ? 'done' : 'rejected', error: (check['ok'] ? nil : "Hidden: #{check['note'] || 'failed its check'}"),
                  usage: usage.merge('mask_version' => Layer::VERSION, 'check' => check, 'outlined' => true, 'tries' => tries, 'notes' => notes) }
        attrs[:usage]['escalated'] = true if usage['batch_model'] == ESCALATE_TO
        render.update!(attrs)
      end
    end
  end
end
