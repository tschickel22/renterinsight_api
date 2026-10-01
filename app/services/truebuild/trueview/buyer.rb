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
        'kitchen' => /cabinet|counter|backsplash|floor|accent|wall ?board|hw /i,
        'bath' => /cabinet|counter|lav|floor|accent|wall ?board/i,
        'exterior' => /siding|shutter|shingle|corner post|shake/i
      }.freeze
      # A choice of nothing ("Accent wall: None") is the photo as built.
      NOTHING = /\A\s*(none|no\b.*|n\/?a|omit.*)\s*\z/i
      PREDRAW_EVERY = 6.hours
      STALE_AFTER = 15.minutes # a job this old was lost (a deploy restarted its worker)   # a model's missing layers are queued at most this often
      DAILY_LIMIT_DEFAULT = 300 # layers a day across the platform; TRUEVIEW_DAILY_LIMIT overrides

      def initialize(company, variant)
        @company = company
        @variant = variant
      end

      # { photos: [{ room:, url:, layers: { option_id => layer_url }, pending: [option_id] }], drawing: n }
      # url is the exact image the layers were cut against, so they line up.
      def call
        plan = self.plan
        done = done_layers(plan)
        skipped = skipped_layers(plan)
        requeue_stale(plan)
        drawing = rows(plan).where(status: %w[queued running]).count
        photos = plan.group_by { |p| p[:photo] }.map do |photo, items|
          layers = items.filter_map { |i| (url = done[[photo, i[:key], i[:prompt]]]) && [i[:option_id], url] }.to_h
          # Finishes this photo will show once drawn, so the page can say so.
          { room: items.first[:room], url: Trueview.sized(photo), layers: layers,
            pending: items.reject { |i| skipped.include?([photo, i[:key], i[:prompt]]) }.map { |i| i[:option_id] }.uniq - layers.keys }
        end
        { photos: photos, drawing: drawing }
      end

      # Queues every missing layer, once per PREDRAW_EVERY, within the daily
      # limit. Returns the number queued.
      def predraw!
        return 0 unless Trueview.configured?(MODEL)
        return 0 unless Rails.cache.write("truebuild:trueview:predraw:#{@variant.id}:v#{Layer::VERSION}", true,
                                          expires_in: PREDRAW_EVERY, unless_exist: true)

        plan = self.plan
        done = done_layers(plan)
        skipped = skipped_layers(plan)
        drawn_before = older_drawings(plan)
        busy = TruebuildRender.where(status: %w[queued running], purpose: 'layer', model_key: MODEL,
                                     source_url: plan.map { |p| p[:photo] }.uniq).pluck(:source_url, :selection_key).to_set
        spec = MODELS.fetch(MODEL)
        queued = 0
        plan.each do |p|
          id = [p[:photo], p[:key], p[:prompt]]
          next if done.key?(id) || skipped.include?(id) || busy.include?([p[:photo], p[:key]])

          # Drawn already under an older cut: cut it again, free, and the
          # daily limit is not spent on it.
          old = drawn_before[id]
          next unless old || within_daily_limit?

          usage = { 'swatch_ids' => p[:swatch_ids], 'predraw' => true }
          usage['recut_from'] = old.id if old
          row = TruebuildRender.create!(catalog_plan_variant_id: @variant.id, room: p[:room], source_url: p[:photo],
                                        selection: p[:selection], selection_key: p[:key], model_key: MODEL,
                                        provider: spec[:provider], model: old&.model || spec[:model], purpose: 'layer',
                                        prompt: p[:prompt], image_url: old&.image_url, usage: usage)
          TruebuildRenderJob.set(queue: :low).perform_later(row.id)
          busy << [p[:photo], p[:key]]
          queued += 1
        end
        queued
      end

      # One entry per photo and offered finish that shows in that photo's room.
      def plan
        @plan ||= begin
          sets = BuyerCatalog.new(@company, @variant).call[:groups].flat_map { |g| g[:color_sets] }
          photos.flat_map do |room, photo|
            sets.select { |s| s[:name].match?(ROOMS[room]) }.flat_map do |set|
              set[:options].reject { |o| o[:name].to_s.match?(NOTHING) }.map do |o|
                selection = TruebuildRender.normalize([{ 'surface' => set[:name], 'value' => o[:name] }])
                swatches = Trueview.swatches_for(@variant, selection)
                { photo: photo, room: room, option_id: o[:id], selection: selection, key: TruebuildRender.key_for(selection),
                  prompt: Trueview.prompt(room: room, selection: selection, swatches: swatches), swatch_ids: swatches.compact.map(&:id) }
              end
            end
          end
        end
      end

      private

      # The first photo of each room the model has.
      def photos
        list = Array(@variant.media&.dig('photos'))
        ROOMS.keys.filter_map { |room| (p = list.find { |x| x['room'] == room && x['url'].present? }) && [room, p['url']] }
      end

      # [photo, selection_key, prompt] => layer_url, current cut only.
      def done_layers(plan)
        return {} if plan.empty?

        TruebuildRender.done.where(purpose: 'layer', model_key: MODEL, source_url: plan.map { |p| p[:photo] }.uniq,
                                   selection_key: plan.map { |p| p[:key] }.uniq)
                       .where.not(layer_url: nil)
                       .select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                       .to_h { |r| [[r.source_url, r.selection_key, r.prompt], r.layer_url] }
      end

      # Lost jobs go back on the queue, or the page would say "still drawing"
      # for ever. Only the row's own job is enqueued again; nothing is redrawn.
      def requeue_stale(plan)
        rows(plan).where(status: %w[queued running]).where(updated_at: ...STALE_AFTER.ago).find_each do |row|
          row.update!(status: 'queued')
          TruebuildRenderJob.set(queue: :low).perform_later(row.id)
        end
      end

      def rows(plan)
        return TruebuildRender.none if plan.empty?

        TruebuildRender.where(purpose: 'layer', model_key: MODEL, source_url: plan.map { |p| p[:photo] }.uniq,
                              selection_key: plan.map { |p| p[:key] }.uniq)
      end

      # Surfaces the photo does not show, under the current cut.
      def skipped_layers(plan)
        rows(plan).where(status: 'skipped').select { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                  .to_set { |r| [r.source_url, r.selection_key, r.prompt] }
      end

      # The newest drawing per finish made under an older cut.
      def older_drawings(plan)
        rows(plan).done.where.not(image_url: nil).order(:id)
                  .reject { |r| r.usage['mask_version'].to_i >= Layer::VERSION }
                  .index_by { |r| [r.source_url, r.selection_key, r.prompt] }
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
