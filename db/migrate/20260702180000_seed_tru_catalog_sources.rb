class SeedTruCatalogSources < ActiveRecord::Migration[8.0]
  # Seeds the two TRU catalog sources (owntru.com) — mirrors the Clayton Epic
  # seed pattern. Rows are created disabled; admins Test + Enable per env so a
  # fresh deploy never kicks off a crawl on prod without a human sign-off.
  #
  # Idempotent by name so it's safe to re-run and also finds admin-created
  # rows that pre-exist (which happened on prod: an admin created "Tru Homes"
  # and "Tru Mini" via the UI with the wrong adapter_type — the migration
  # normalizes their adapter_type / config).
  SOURCES = [
    { name: 'Tru Homes', base_url: 'https://owntru.com/model-lines/tru-origin/' },
    { name: 'Tru Mini',  base_url: 'https://owntru.com/model-lines/tru-mini/' }
  ].freeze

  def up
    say_with_time 'Seeding TRU catalog sources' do
      SOURCES.each do |s|
        cs = CatalogSource.find_or_initialize_by(name: s[:name])
        cs.adapter_type = 'tru_model_line'
        cs.base_url     = s[:base_url]
        cs.config       = (cs.config || {}).merge(
          'crawl_delay'      => 5,
          # TRU pages have no on-page description — dropping description
          # from the health check keeps runs at status='success' so dealers
          # can subscribe (see Clayton Epic seed for the same tuning).
          'untracked_fields' => Array(cs.config&.dig('untracked_fields')) | ['description']
        )
        cs.enabled              = false if cs.enabled.nil?
        cs.schedule           ||= 'weekly'
        cs.extraction_threshold = 0.85 if cs.extraction_threshold.blank?
        cs.save!
        say "  #{s[:name]} (id=#{cs.id})", true
      end
    end
  end

  def down
    say_with_time 'Removing TRU catalog sources (soft-delete)' do
      SOURCES.each do |s|
        cs = CatalogSource.find_by(name: s[:name])
        next unless cs

        cs.update_columns(is_deleted: true, deleted_at: Time.current)
        say "  soft-deleted #{s[:name]} (id=#{cs.id})", true
      end
    end
  end
end
