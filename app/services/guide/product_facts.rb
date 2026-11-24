# frozen_string_literal: true

module Guide
  # What DealerTide does and does not do, for the help assistant (E118).
  #
  # Two sources: every plan module's own name and description
  # (PlatformModule::MODULES, so every module is covered), and
  # db/guide/capabilities.yml for what is NOT offered and answers to common
  # "can it do X" questions. The assistant may only say "we don't offer that"
  # when an entry here says offered: false. A feature missing from the Atlas
  # is not proof we lack it.
  class ProductFacts
    FILE = Rails.root.join('db/guide/capabilities.yml')

    def self.entries
      @entries = nil if Rails.env.development?
      @entries ||= begin
        listed = YAML.safe_load_file(FILE).map do |e|
          { topic: e['topic'], offered: e['offered'] != false, about: e['nearest'], keywords: Array(e['keywords']) }
        end
        modules = PlatformModule::MODULES.map do |key, m|
          not_offered = SetupAreas::AREAS.dig(key, :not_offered)
          { topic: m[:name], module: key, offered: !not_offered, about: m[:description].to_s,
            keywords: [m[:name], key.split('.').last.tr('_', ' ')] }
        end
        (listed + modules).freeze
      end
    end

    def self.call(topic)
      words = topic.to_s.downcase.scan(/[a-z0-9&]+/).reject { |w| w.length < 3 }
      return { error: 'Say what feature to look up.' } if words.empty?

      scored = entries.map do |e|
        text = ([e[:topic]] + e[:keywords]).join(' ').downcase
        phrase = e[:keywords].any? { |k| topic.to_s.downcase.include?(k.downcase) } ? 5 : 0
        [e, phrase + words.count { |w| text.include?(w) } * 2 + words.count { |w| e[:about].to_s.downcase.include?(w) }]
      end
      hits = scored.select { |_, s| s >= 2 }.sort_by { |_, s| -s }.first(4).map(&:first)
      return { found: false, note: 'Nothing on record for that. Do not say whether it is offered; treat it as no_help.' } if hits.empty?

      { found: true, matches: hits.map { |e| e.slice(:topic, :module, :offered, :about).compact } }
    end
  end
end
