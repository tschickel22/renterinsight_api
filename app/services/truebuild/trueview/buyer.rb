# frozen_string_literal: true

module Truebuild
  module Trueview
    # TrueView in the buyer's designer: the model's real kitchen, bath and
    # exterior photos with a layer per finish the dealer offers, stacked in
    # the browser as the buyer picks. Nothing is drawn while a buyer waits:
    # the first visit to a model queues its layers in the background, and a
    # surface shows as built until its layer is ready.
    #
    # Layers are keyed by photo, finish, image model and prompt, not by
    # dealer, so every dealer selling a model shares one set of drawings.
    class Buyer
      MODEL = 'nb2-lite' # chosen in the lab bake-off: cheapest, fastest, looked best
      ROOMS = {
        'kitchen' => /cabinet|counter|backsplash|floor|accent|wall ?board|hw |appliance|refrigerator/i,
        'bath' => /cabinet|counter|lav|floor|accent|wall ?board/i,
        'exterior' => /siding|shutter|shingle|corner post|shake/i
      }.freeze
      # A choice of nothing ("Accent wall: None") is the photo as built.
      NOTHING = /\A\s*(none|no\b.*|n\/?a|omit.*)\s*\z/i
      PREDRAW_EVERY = 6.hours # a model's missing layers are queued at most this often
      STALE_AFTER = 15.minutes # without Solid Queue to ask, a job this old was lost
      DAILY_LIMIT_DEFAULT = 300 # layers a day across the platform; TRUEVIEW_DAILY_LIMIT overrides

      def initialize(company, variant)
        @company = company
        @variant = variant
      end

      # { photos: [{ room:, url:, layers: { option_id => layer_url }, pending: [option_id] }], drawing: n }
      # url is the exact image the layers were cut against, so they line up.
      def call
        plan = self.plan
        # A drawing under an older cut shows until its re-cut is done, so a
        # Layer::VERSION bump does not blank every finish at once.
        hidden = hidden_layers(plan)
        done = older_layers(plan).except(*hidden, *failed_now(plan)).merge(done_layers(plan))
        skipped = skipped_layers(plan)
        requeue_stale(plan)
        drawing = rows(plan).where(status: %w[queued running]).count
        photos = plan.group_by { |p| p[:photo] }.map do |photo, items|
          layers = items.filter_map { |i| (url = done[[photo, i[:key], i[:prompt]]]) && [i[:option_id], url] }.to_h
          # Finishes this photo will show once drawn, so the page can say so.
          { room: items.first[:room], url: Trueview.sized(photo), layers: layers,
            pending: items.reject { |i| (skipped | hidden).include?([photo, i[:key], i[:prompt]]) }.map { |i| i[:option_id] }.uniq - layers.keys,
            # Drawn, but held back by its check until someone reviews it.
            unavailable: items.select { |i| hidden.include?([photo, i[:key], i[:prompt]]) }.map { |i| i[:option_id] }.uniq - layers.keys,
            # Picked but not in this photo (a house with no shutters), so the page can say so.
            not_shown: items.select { |i| skipped.include?([photo, i[:key], i[:prompt]]) }.map { |i| i[:option_id] }.uniq }
        end
        # The surface each finish paints, so Compare treats the cabinet chips
        # and the cabinet upgrades (or a fridge and an appliance package) as
        # one category with one pick on each side, not two stacked layers.
        surfaces = plan.to_h do |p|
          key = Surfaces.category(p[:selection].first&.dig('surface'))
          [p[:option_id], key == 'refrigerator' ? 'appliances' : key]
        end
        { photos: photos, drawing: drawing, surfaces: surfaces.compact }
      end

      # What BuyerCatalog does not offer, as option id sets, under the
      # current cut. Cached briefly, as the designer asks on every load.
      #   failed        its drawing failed its check on a photo
      #   not_pictured  no photo of its room shows the surface (shutter
      #                 colors for a home photographed without shutters)
      def self.held_back(company, variant)
        Rails.cache.fetch("truebuild:trueview:held:v2:#{Layer::VERSION}:#{variant.id}", expires_in: 5.minutes) do
          new(company, variant).held_back
        end
      end

      def held_back
        plan = self.plan
        failed = hidden_layers(plan) - done_layers(plan).keys
        skipped = skipped_layers(plan)
        ids = ->(items) { items.map { |p| p[:option_id] }.uniq.to_set }
        { failed: ids.call(plan.select { |p| failed.include?([p[:photo], p[:key], p[:prompt]]) }),
          not_pictured: ids.call(plan.group_by { |p| p[:option_id] }
                                     .select { |_, ps| ps.all? { |p| skipped.include?([p[:photo], p[:key], p[:prompt]]) } }
                                     .values.flatten) }
      end

      # Queues every missing layer, once per PREDRAW_EVERY, within the daily
      # limit. Returns the number queued.
      # force: draw now (after the photos were picked), not once per PREDRAW_EVERY.
      def predraw!(force: false)
        # Claude picks the photos first; drawing waits for it, so nothing is
        # drawn on a photo about to be replaced.
        if PhotoChoice.needs_pick?(@variant)
          if Rails.cache.write("truebuild:trueview:pick:#{@variant.id}", true, expires_in: 30.minutes, unless_exist: true)
            TruebuildPhotoPickJob.perform_later(@company.id, @variant.id)
          end
          return 0
        end
        Rails.cache.delete("truebuild:trueview:predraw:#{@variant.id}:v#{Layer::VERSION}") if force
        return 0 unless Trueview.configured?(MODEL)
        return 0 unless Rails.cache.write("truebuild:trueview:predraw:#{@variant.id}:v#{Layer::VERSION}", true,
                                          expires_in: PREDRAW_EVERY, unless_exist: true)

        queue_missing!
      end

      # Plan entries not drawn under the current cut, and not being drawn now,
      # as [entry, older drawing to cut again or nil]. A drawing is stored by
      # photo and finish, so one already made for another model with the same
      # photo (another factory's copy of it) counts as drawn.
      def missing(plan = self.plan)
        done = done_layers(plan)
        retry_of = held_before_escalation(plan)
        skipped = skipped_layers(plan) | (hidden_layers(plan) - retry_of.keys)
        drawn_before = older_drawings(plan)
        busy = TruebuildRender.where(status: %w[queued running], purpose: 'layer', model_key: MODEL,
                                     source_url: plan.map { |p| p[:photo] }.uniq).pluck(:source_url, :selection_key).to_set
        plan.filter_map do |p|
          id = [p[:photo], p[:key], p[:prompt]]
          next if done.key?(id) || skipped.include?(id) || busy.include?([p[:photo], p[:key]])

          busy << [p[:photo], p[:key]]
          [p, drawn_before[id], retry_of[id]]
        end
      end

      # Queues what is missing. A buyer's visit is held to the daily limit; a
      # factory run (run:) pays from its own budget, checked before it gets
      # here, and waits behind buyers in the queue. Returns the number queued.
      def queue_missing!(run: nil)
        # Only a factory run draws (Tom, 2026-10-05): a buyer's visit uses
        # what was already paid for and draws nothing, so every cent spent
        # is a run someone started and budgeted. What is not drawn yet shows
        # the home as photographed.
        return 0 unless run
        return 0 if Credits.out? # each would fail at once

        spec = MODELS.fetch(MODEL)
        queued = 0
        missing.each do |p, old, held|
          old = nil if held
          # Drawn already under an older cut: cut it again, free, and the
          # daily limit is not spent on it.
          next unless old || run || within_daily_limit?

          # A skip from an outline since turned down and tried again gives way to this attempt.
          TruebuildRender.where(source_url: p[:photo], selection_key: p[:key], prompt: p[:prompt], purpose: 'layer', status: 'skipped')
                         .update_all(status: 'superseded', updated_at: Time.current)
          usage = { 'swatch_ids' => p[:swatch_ids], 'predraw' => true }
          usage['recut_from'] = old.id if old
          if held
            # Held back before the larger model was tried: one try on it, told
            # everything the checks found.
            usage.merge!('draw_with' => Trueview::ESCALATE_TO, 'reviewer_note' => FactoryRun.notes(held).presence).compact!
            held.update!(status: 'superseded')
          end
          usage['factory_run_id'] = run.id if run
          row = TruebuildRender.create!(catalog_plan_variant_id: @variant.id, room: p[:room], source_url: p[:photo],
                                        selection: p[:selection], selection_key: p[:key], model_key: MODEL,
                                        provider: spec[:provider], model: old&.model || spec[:model], purpose: 'layer',
                                        prompt: p[:prompt], image_url: old&.image_url, usage: usage)
          if run
            FactoryRun.dispatch(row, run)
          else
            TruebuildRenderJob.set(queue: :low, priority: 0).perform_later(row.id)
          end
          queued += 1
        end
        queued
      end

      # One entry per photo and offered finish that shows in that photo's room.
      def plan
        @plan ||= begin
          # The whole price book, whatever this dealer shows buyers: drawings are
          # shared by every dealer, and a dealer may show more later.
          groups = BuyerCatalog.finish_groups(@variant)
          finishes = finish_choices(groups)
          photos.flat_map do |room, photo|
            finishes.select { |f| f[:surface].match?(ROOMS[room]) }.map do |f|
              selection = TruebuildRender.normalize([{ 'surface' => f[:surface], 'value' => f[:value] }])
              swatches = Trueview.swatches_for(@variant, selection)
              { photo: photo, room: room, option_id: f[:option_id], selection: selection, key: TruebuildRender.key_for(selection),
                prompt: Trueview.prompt(room: room, selection: selection, swatches: swatches), swatch_ids: swatches.compact.map(&:id) }
            end
          end
        end
      end

      # Everything a buyer can pick that changes how a room looks, as
      # [{ option_id:, surface:, value: }]: each color, plus the paid upgrades
      # that are really a finish. "HW DestinWhite IPO Wrapped" is Destin White
      # cabinets, the same drawing as the Destin White chip; an appliance
      # package or refrigerator swap is the appliances.
      def finish_choices(groups)
        colors = groups.flat_map { |g| g[:color_sets] }.flat_map do |set|
          set[:options].reject { |o| o[:name].to_s.match?(NOTHING) }.map { |o| { option_id: o[:id], surface: set[:name], value: o[:name] } }
        end
        upgrades = groups.flat_map { |g| g[:options] }.filter_map do |o|
          if o[:family] == 'cabinet finish' && (color = cabinet_color(o[:name]))
            { option_id: o[:id], surface: 'Cabinets', value: color }
          elsif o[:family].to_s.start_with?('refrigerator')
            { option_id: o[:id], surface: 'Refrigerator', value: o[:name].to_s.gsub(/\(.*?\)/, ' ').squish }
          elsif o[:family] == 'appliance package'
            { option_id: o[:id], surface: 'Appliances', value: o[:name].to_s.gsub(/\(.*?\)/, ' ').squish }
          end
        end
        colors + upgrades
      end

      # "HW DestinWhite IPO Wrapped" => "Destin White"; "Mixed Cabinets IPO HW" => nil
      # (two tones, no single color to draw).
      def cabinet_color(name)
        color = name.to_s.gsub(/\(.*?\)/, ' ').sub(/\bIPO\b.*\z/i, ' ')
                    .gsub(/\b(HW|hardwood|cabs?|cabinets?|stiles?|colors?)\b|\//i, ' ')
                    .gsub(/([a-z])([A-Z])/, '\\1 \\2').squish
        color.presence unless color.match?(/mixed/i)
      end

      private

      # The photos drawn on, per room (PhotoChoice).
      def photos
        PhotoChoice.photos(@variant)
      end

      # A drawing belongs to the plan by its photo and finish, whatever words
      # drew it. Matched by the exact prompt, every wording improvement threw
      # away what was paid for: on staging's Bay Port, 278 of 543 drawings
      # stopped matching after appliance descriptions and decor samples were
      # added to prompts, and buyers' visits drew them all again. A drawing
      # made with the current words wins over an older one for the same finish.
      def planned_prompts(plan)
        plan.to_h { |p| [[p[:photo], p[:key]], p[:prompt]] }
      end

      def plan_key(row, prompts)
        [row.source_url, row.selection_key, prompts[[row.source_url, row.selection_key]] || row.prompt]
      end

      # Current wording last, so it wins in a hash built from these rows.
      def current_last(rows, prompts)
        rows.sort_by { |r| [prompts[[r.source_url, r.selection_key]] == r.prompt ? 1 : 0, r.id] }
      end

      # [photo, selection_key, prompt] => layer_url, current cut only.
      def done_layers(plan)
        return {} if plan.empty?

        prompts = planned_prompts(plan)
        rows = TruebuildRender.done.where(purpose: 'layer', model_key: MODEL, source_url: plan.map { |p| p[:photo] }.uniq,
                                          selection_key: plan.map { |p| p[:key] }.uniq)
                              .where.not(layer_url: nil)
                              .select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
        current_last(rows, prompts).to_h { |r| [plan_key(r, prompts), r.layer_url] }
      end

      # Lost jobs go back on the queue, or the page would say "still drawing"
      # for ever. Only the row's own job is enqueued again; nothing is redrawn.
      def requeue_stale(plan)
        TruebuildRenderJob.orphaned(rows(plan), stale_after: STALE_AFTER)
                          .each { |row| TruebuildRenderJob.requeue(row, queue: :low) }
      end

      def rows(plan)
        return TruebuildRender.none if plan.empty?

        TruebuildRender.where(purpose: 'layer', model_key: MODEL, source_url: plan.map { |p| p[:photo] }.uniq,
                              selection_key: plan.map { |p| p[:key] }.uniq)
      end

      # Surfaces the photo does not show, under the current cut. Not one whose
      # outline Claude turned down and is due another try (Surfaces.retry_due?):
      # drawing it again outlines it again first.
      def skipped_layers(plan)
        due = TruebuildSurfaceMask.where(source_url: plan.map { |p| p[:photo] }.uniq, version: Surfaces::VERSION).to_a
                                  .select { |m| Surfaces.retry_due?(m) }.to_set { |m| [m.source_url, m.surface] }
        prompts = planned_prompts(plan)
        rows(plan).where(status: 'skipped').select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                  .reject { |r| due.include?([r.source_url, Surfaces.category(r.selection.first&.dig('surface'))]) }
                  .to_set { |r| plan_key(r, prompts) }
      end

      # Held back under the current cut without the larger model having
      # tried it (drawn before that try existed): [photo, key, prompt] => row.
      def held_before_escalation(plan)
        waiting = TruebuildSurfaceMask.where(source_url: plan.map { |p| p[:photo] }.uniq, version: Surfaces::VERSION)
                                      .where("usage->>'redo_pending' = 'true'").where(updated_at: 1.hour.ago..) # a failed redo stops holding them
                                      .pluck(:source_url, :surface).to_set
        rows(plan).where(status: 'rejected').select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                  .reject { |r| waiting.include?([r.source_url, Surfaces.category(r.selection.first&.dig('surface'))]) }
                  .reject { |r| r.usage['escalated'] || r.usage['draw_with'] == Trueview::ESCALATE_TO }
                  .then { |rs| current_last(rs, planned_prompts(plan)) }
                  .to_h { |r| [plan_key(r, planned_prompts(plan)), r] }
      end

      # Failed their check under the current cut: not redrawn on every visit.
      def hidden_layers(plan)
        prompts = planned_prompts(plan)
        rows(plan).where(status: 'rejected').select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                  .to_set { |r| plan_key(r, prompts) }
      end

      # [photo, selection_key, prompt] => layer_url of a passed drawing
      # under an older cut, newest first. Only one cut by its surface's
      # outline: cut by what it changed, each accent color sat on its own wall.
      def older_layers(plan)
        prompts = planned_prompts(plan)
        rows = rows(plan).done.where.not(layer_url: nil).order(:id)
                         .reject { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                         .select { |r| r.usage['outlined'] || Surfaces.category(r.selection.first&.dig('surface')).nil? }
        current_last(rows, prompts).to_h { |r| [plan_key(r, prompts), r.layer_url] }
      end

      # Failed under the current cut, including one set aside for a retry on
      # the larger model: its older drawing must not show meanwhile.
      def failed_now(plan)
        prompts = planned_prompts(plan)
        rows(plan).where(status: %w[rejected superseded]).select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                  .map { |r| plan_key(r, prompts) }.uniq
      end

      # The newest drawing per finish made under an older cut. A rejected one
      # counts: cut again, it is checked again (now against the factory's
      # sample) for the price of the check, not a new drawing.
      def older_drawings(plan)
        prompts = planned_prompts(plan)
        rows = rows(plan).where(status: %w[done rejected]).where.not(image_url: nil).order(:id)
                         .reject { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
        current_last(rows, prompts).index_by { |r| plan_key(r, prompts) }
      end

      def within_daily_limit?
        limit = (ENV['TRUEVIEW_DAILY_LIMIT'].presence || DAILY_LIMIT_DEFAULT).to_i
        key = "truebuild:trueview:daily:#{Date.current}"
        count = Rails.cache.increment(key, 1, expires_in: 2.days) || (Rails.cache.write(key, 1, expires_in: 2.days) && 1)
        count.to_i <= limit
      end
    end
  end
end
