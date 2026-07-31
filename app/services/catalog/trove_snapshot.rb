# frozen_string_literal: true

module Catalog
  # Platform-scoped store for a captured Trove catalog.
  #
  # Trove sites sit behind a Vercel bot checkpoint that challenges any
  # non-browser client, so a live crawl is gated on the host allowlisting us.
  # A snapshot lets a source run the REAL ingestion path (Test, Run Now,
  # vehicles, images, change detection) from data captured out of band, and
  # flipping back to live is a config change: drop `snapshot_key`.
  #
  # Payload shape (schema trove.catalog.snapshot/v1):
  #   { 'schema', 'base_url', 'supplier_name', 'captured_at', 'home_count',
  #     'homes' => [ { 'short_id', 'name', 'supplier_sku', 'price' => {...},
  #                    'details' => {...}, 'images' => [...] }, ... ] }
  #
  # The adapter parses snapshot homes and live-crawled homes through the SAME
  # extractors, so a snapshot-backed run is a faithful rehearsal of a live one.
  class TroveSnapshot
    KEY_PREFIX = 'trove_snapshot'
    SCHEMA     = 'trove.catalog.snapshot/v1'

    class << self
      # `key` is the bare slug ("legacy_housing"); stored under a namespaced
      # setting key so snapshots can never collide with other platform settings.
      def read(key)
        raw = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, setting_key(key))
        raw.is_a?(Hash) ? raw : nil
      end

      def write(key, payload)
        raise ArgumentError, 'snapshot payload must be a Hash' unless payload.is_a?(Hash)

        normalized = payload.deep_stringify_keys
        unless normalized['schema'] == SCHEMA
          raise ArgumentError, "unexpected snapshot schema #{normalized['schema'].inspect}, want #{SCHEMA}"
        end

        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, setting_key(key), normalized)
        normalized
      end

      def delete(key)
        Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, setting_key(key), nil)
      end

      def exists?(key)
        read(key).present?
      end

      # Slugs of every stored snapshot, for the admin picker.
      def keys
        Setting.where(scope_type: 'Platform', scope_id: PlatformSetting::PLATFORM_SCOPE_ID)
               .where('key LIKE ?', "#{KEY_PREFIX}:%")
               .pluck(:key)
               .map { |k| k.delete_prefix("#{KEY_PREFIX}:") }
               .sort
      end

      def setting_key(key)
        "#{KEY_PREFIX}:#{key.to_s.strip}"
      end
    end
  end
end
