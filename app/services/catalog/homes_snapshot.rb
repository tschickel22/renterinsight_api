# frozen_string_literal: true

module Catalog
  # Platform-scoped store for a captured catalog of ALREADY-PARSED homes.
  #
  # Sibling of TroveSnapshot, deliberately separate rather than a refactor of
  # it: Legacy runs off that store today and this needs to ship for a demo, so
  # the two stay independent until there is a reason to merge them.
  #
  # WHY PARSED HOMES, NOT RAW PAGES. Trove's snapshot keeps each home's raw
  # record and re-parses it, so a snapshot run exercises the extractors too.
  # That is the better property, and it does not survive contact with a site
  # whose raw form is HTML: Adventure's 130 pages are ~21MB, which has no
  # business in a Setting row. Storing NormalizedHome#to_h instead costs the
  # extractor rehearsal and lands around 800KB.
  #
  # Change detection still works across a re-capture. NormalizedHome#content_hash
  # is computed from the tracked fields and the image SOURCE urls, and it
  # survives the to_h/from_h round trip, so IngestionService compares a
  # snapshot-backed home against a live-crawled one on equal terms: re-uploading
  # updates only what actually changed and leaves dealer edits alone.
  #
  # Payload shape (schema catalog.homes.snapshot/v1):
  #   { 'schema', 'adapter_type', 'base_url', 'source_name', 'captured_at',
  #     'home_count', 'homes' => [ NormalizedHome#to_h, ... ] }
  class HomesSnapshot
    KEY_PREFIX = 'homes_snapshot'
    SCHEMA     = 'catalog.homes.snapshot/v1'

    class << self
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
      #
      # Deleting writes a nil VALUE rather than removing the row, so the key
      # survives its own deletion. Listing it would offer the admin a phantom
      # snapshot with 0 homes, and binding a source to one now fails closed —
      # correct, but baffling. Keep only keys that still read back with homes.
      def keys
        Setting.where(scope_type: 'Platform', scope_id: PlatformSetting::PLATFORM_SCOPE_ID)
               .where('key LIKE ?', "#{KEY_PREFIX}:%")
               .pluck(:key)
               .map { |k| k.delete_prefix("#{KEY_PREFIX}:") }
               .select { |k| Array(read(k)&.[]('homes')).any? }
               .sort
      end

      # Builds a payload from parsed homes. Used by the capture task and by any
      # caller that already holds NormalizedHomes.
      def build(source:, homes:, captured_at: Time.current)
        {
          'schema'       => SCHEMA,
          'adapter_type' => source.adapter_type,
          'base_url'     => source.base_url,
          'source_name'  => source.name,
          'captured_at'  => captured_at.utc.iso8601,
          'home_count'   => homes.size,
          'homes'        => homes.map { |h| h.respond_to?(:to_h) ? h.to_h : h }
        }
      end

      def setting_key(key)
        "#{KEY_PREFIX}:#{key}"
      end
    end
  end
end
