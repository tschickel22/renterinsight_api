class SeedClaytonEpicRegionSources < ActiveRecord::Migration[8.0]
  # Seed the six Clayton Epic Experience region sources so staging and prod
  # get the same catalog shelf that local dev already has. Rows are created
  # with enabled=false; admins Test + Enable each per environment so we never
  # start a full crawl on deploy.
  #
  # Idempotent by name: re-running (or hitting a row a human already created
  # via the admin UI) just updates the adapter_type / base_url / config to the
  # canonical values instead of duplicating.
  REGIONS = [
    { id: 1, label: 'West' },
    { id: 2, label: 'Central' },
    { id: 3, label: 'South' },
    { id: 4, label: 'East' },
    { id: 5, label: 'North' },
    { id: 6, label: 'North-Central' }
  ].freeze

  def up
    say_with_time 'Seeding Clayton Epic region catalog sources' do
      REGIONS.each do |r|
        name = "Clayton Epic - #{r[:label]}"
        cs = CatalogSource.find_or_initialize_by(name: name)
        cs.adapter_type = 'clayton_epic_region'
        cs.base_url     = "https://claytonepicexperience.com/homes/?region=#{r[:id]}"
        cs.config       = (cs.config || {}).merge(
          'crawl_delay'      => 5,
          'region_id'        => r[:id],
          # Clayton Epic pages don't publish an on-page description, so drop
          # description from the health check — otherwise every run degrades
          # even though extraction is fine (same tuning we applied to TRU).
          'untracked_fields' => Array(cs.config&.dig('untracked_fields')) | ['description']
        )
        # Preserve existing enabled/schedule/threshold on rows a human already
        # customized. New rows get safe defaults; nothing auto-enables.
        cs.enabled              = false if cs.enabled.nil?
        cs.schedule           ||= 'weekly'
        cs.extraction_threshold = 0.85 if cs.extraction_threshold.blank?
        cs.save!
        say "  #{cs.new_record? ? 'created' : 'updated'} #{name} (id=#{cs.id})", true
      end
    end
  end

  def down
    say_with_time 'Removing Clayton Epic region catalog sources (soft-delete)' do
      REGIONS.each do |r|
        name = "Clayton Epic - #{r[:label]}"
        cs = CatalogSource.find_by(name: name)
        next unless cs
        # Soft-delete so any dealer subscriptions / scrape history stay
        # referenceable — re-running #up restores them cleanly.
        cs.update_columns(is_deleted: true, deleted_at: Time.current)
        say "  soft-deleted #{name} (id=#{cs.id})", true
      end
    end
  end
end
