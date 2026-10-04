# frozen_string_literal: true

# Moving confidential files out of the public bucket (see PrivateFiles).
#
# Staging and production share the legacy bucket, and both put files under the
# same "agreements/<company_id>/" style folders, so a folder alone does not say
# which environment a file belongs to. Each environment therefore moves only
# the files ITS database points at, into ITS private bucket.
#
# Order, per environment:
#   bin/rails private_files:configure_cors
#   bin/rails private_files:migrate                  # dry run, reports only
#   bin/rails private_files:migrate APPLY=1          # copy, then rewrite rows
#   bin/rails private_files:purge_legacy             # dry run
#   bin/rails private_files:purge_legacy CONFIRM=purge ALL_ENVS_MIGRATED=yes
#
# Purge only after migrate APPLY=1 has finished in EVERY environment that uses
# the legacy bucket (local dev databases included). A database restored from
# another's dump points at the same objects, and purging before the other has
# copied them would lose its files.
#
# migrate is safe to re-run. purge_legacy only deletes a legacy object once a
# copy is confirmed in this environment's private bucket, and removes every
# version of it (the legacy bucket is versioned, so a plain delete would leave
# the old version behind).
namespace :private_files do
  CONFIDENTIAL_PREFIXES = %w[
    agreements/ bills/ journal_entries/ imports/ campaign_attachments/ nurture_attachments/
    contractor-work-logs/ projects/ custom-fields/ site-profiles/uploads/
  ].freeze
  # Folders that also hold public images; only these subfolders are confidential.
  CONFIDENTIAL_PATTERNS = [%r{\Avehicles/\d+/\d+/documents/}, %r{\Ausers/\d+/\d+/signatures/}].freeze

  def pf_confidential_key?(key)
    CONFIDENTIAL_PREFIXES.any? { |p| key.start_with?(p) } || CONFIDENTIAL_PATTERNS.any? { |r| key.match?(r) }
  end

  desc 'Allow the frontends to fetch private files (the PDF viewer reads them cross-origin)'
  task configure_cors: :environment do
    bucket = PrivateFiles.bucket
    origins = %w[
      https://dealertide.com https://*.dealertide.com https://*.mydealertide.com
      https://*.renterinsight.com https://*.landlordinsight.com
      http://localhost:* https://localhost:*
    ]
    PrivateFiles.client.put_bucket_cors(
      bucket: bucket,
      cors_configuration: { cors_rules: [{ allowed_origins: origins, allowed_methods: %w[GET HEAD],
                                           allowed_headers: ['*'], expose_headers: %w[Content-Length Content-Type ETag],
                                           max_age_seconds: 3600 }] }
    )
    puts "CORS set on #{bucket}: #{origins.join(', ')}"
  end

  desc 'Copy confidential files this database refers to into the private bucket and rewrite the rows (APPLY=1 to write)'
  task migrate: :environment do
    apply = ENV['APPLY'] == '1'
    legacy = PrivateFiles.legacy_bucket
    target = PrivateFiles.bucket
    abort "PRIVATE_DOCUMENTS_BUCKET (#{target}) must differ from the legacy bucket" if target == legacy

    puts "#{apply ? 'APPLYING' : 'DRY RUN'}: #{legacy} -> #{target} (#{Rails.env})"
    stats = Hash.new { |h, k| h[k] = Hash.new(0) }
    missing = []

    # Returns the new stored value, or nil when nothing should change.
    move = lambda do |label, value, durable: false|
      b, k = PrivateFiles.locate(value)
      next nil unless k && b == legacy

      unless PrivateFiles.exists?(value)
        stats[label][:missing] += 1
        missing << "#{label}: #{k}"
        next nil
      end
      stats[label][:moved] += 1
      new_ref = apply ? PrivateFiles.copy_to_private(value) : PrivateFiles.ref(k, target)
      durable ? PrivateFiles.durable_url(new_ref) : new_ref
    end

    columns = {
      Agreement => %i[document_url sealed_document_url], AgreementTemplate => %i[document_url example_document_url],
      AgreementAttachment => %i[file_url], AgreementSigner => %i[signature_url initials_url],
      User => %i[signature_url initials_url], ProjectDocument => %i[file_url],
      VehicleDocument => %i[file_url], ProjectCostItem => %i[receipt_url],
      ImportJob => %i[source_file_url image_zip_url], SiteContentProfile => %i[document_s3_key]
    }
    columns.each do |model, cols|
      cols.each do |col|
        model.where.not(col => [nil, '']).find_each do |rec|
          v = rec[col]
          next if v.to_s.start_with?('data:')
          # Bare keys in these two columns are ours; elsewhere a bare string is not a file.
          next if !v.to_s.include?('://') && !%i[source_file_url image_zip_url document_s3_key].include?(col)

          new_v = move.call("#{model.name}.#{col}", v)
          rec.update_columns(col => new_v) if new_v && apply
        end
      end
    end

    lists = { Agreement => :document_urls, AgreementTemplate => :document_urls, ContractorAssignment => :completion_photos }
    lists.each do |model, col|
      model.where("jsonb_array_length(COALESCE(#{col}, '[]'::jsonb)) > 0").find_each do |rec|
        changed = false
        list = Array(rec[col]).map do |v|
          next v unless v.is_a?(String)

          nv = move.call("#{model.name}.#{col}", v)
          changed ||= !nv.nil?
          nv || v
        end
        rec.update_columns(col => list) if changed && apply
      end
    end

    attachments = { Bill => %w[url], JournalEntry => %w[url], AssignmentWorkLog => %w[url thumbnail_url] }
    attachments.each do |model, fields|
      model.where("jsonb_array_length(COALESCE(attachments, '[]'::jsonb)) > 0").find_each do |rec|
        changed = false
        list = Array(rec.attachments).map do |att|
          next att unless att.is_a?(Hash)

          att = att.dup
          fields.each do |f|
            nv = move.call("#{model.name}.attachments.#{f}", att[f]) if att[f].present?
            (att[f] = nv; changed = true) if nv
          end
          att
        end
        rec.update_columns(attachments: list) if changed && apply
      end
    end

    # Campaign and nurture steps keep the bare key (the UI matches on it) and
    # gain a file_ref; tracked links for those attachments carry the key too.
    [CampaignStep, NurtureStep].each do |model|
      model.where("jsonb_array_length(COALESCE(attachments, '[]'::jsonb)) > 0").find_each do |rec|
        changed = false
        list = Array(rec.attachments).map do |att|
          next att unless att.is_a?(Hash) && att['s3_key'].present? && att['file_ref'].blank?

          nv = move.call("#{model.name}.attachments", att['s3_key'])
          next att unless nv

          changed = true
          att.merge('file_ref' => nv)
        end
        rec.update_columns(attachments: list) if changed && apply
      end
    end
    TrackedLink.where("s3_key LIKE 'campaign_attachments/%' OR s3_key LIKE 'nurture_attachments/%'").find_each do |tl|
      nv = move.call('TrackedLink.s3_key', tl.s3_key)
      tl.update_columns(s3_key: nv) if nv && apply
    end

    # Custom field file values: { "url" => ..., "s3_key" => "custom-fields/..." },
    # alone or in an array, stored by the client. They get durable links.
    fix_cf = lambda do |label, node|
      case node
      when Array
        changed = false
        out = node.map { |n| r, c = fix_cf.call(label, n); changed ||= c; r }
        [out, changed]
      when Hash
        if node['s3_key'].to_s.start_with?('custom-fields/') && node['url'].present?
          nv = move.call(label, node['url'], durable: true)
          nv ? [node.merge('url' => nv), true] : [node, false]
        else
          changed = false
          out = node.transform_values { |n| r, c = fix_cf.call(label, n); changed ||= c; r }
          [out, changed]
        end
      else
        [node, false]
      end
    end
    Rails.application.eager_load!
    ApplicationRecord.descendants.select { |m| m.table_exists? && m.column_names.include?('custom_field_values') && !m.abstract_class? }
                     .uniq(&:table_name).each do |model|
      model.where("custom_field_values::text LIKE '%custom-fields/%'").find_each do |rec|
        out, changed = fix_cf.call("#{model.name}.custom_field_values", rec.custom_field_values)
        rec.update_columns(custom_field_values: out) if changed && apply
      end
    end

    stats.sort.each { |label, s| puts format('  %-45s moved %5d  missing %4d', label, s[:moved], s[:missing]) }
    puts "Missing source objects (left unchanged):\n  #{missing.first(50).join("\n  ")}" if missing.any?
    puts apply ? 'Done.' : 'Dry run only. Re-run with APPLY=1 to copy files and rewrite rows.'
  end

  desc 'Delete legacy public copies that are confirmed in this environment\'s private bucket (CONFIRM=purge to delete)'
  task purge_legacy: :environment do
    delete = ENV['CONFIRM'] == 'purge'
    if delete && ENV['ALL_ENVS_MIGRATED'] != 'yes'
      abort 'Refusing to delete: set ALL_ENVS_MIGRATED=yes once migrate APPLY=1 has run in every environment ' \
            'that uses the legacy bucket (production, staging and any local copies).'
    end
    legacy = PrivateFiles.legacy_bucket
    target = PrivateFiles.bucket
    abort 'PRIVATE_DOCUMENTS_BUCKET must differ from the legacy bucket' if target == legacy
    client = PrivateFiles.client

    purged = 0
    kept = []
    prefixes = CONFIDENTIAL_PREFIXES + %w[vehicles/ users/]
    prefixes.each do |prefix|
      token = nil
      loop do
        resp = client.list_objects_v2(bucket: legacy, prefix: prefix, continuation_token: token)
        resp.contents.each do |obj|
          next unless pf_confidential_key?(obj.key)

          unless PrivateFiles.exists?(PrivateFiles.ref(obj.key, target))
            kept << obj.key
            next
          end
          purged += 1
          next unless delete

          versions = client.list_object_versions(bucket: legacy, prefix: obj.key)
          ids = (versions.versions + versions.delete_markers).select { |v| v.key == obj.key }
                                                            .map { |v| { key: v.key, version_id: v.version_id } }
          client.delete_objects(bucket: legacy, delete: { objects: ids, quiet: true }) if ids.any?
        end
        break unless resp.is_truncated

        token = resp.next_continuation_token
      end
    end

    puts "#{delete ? 'Deleted' : 'Would delete'} #{purged} legacy objects (every version) that are safe in #{target}."
    puts "#{kept.size} confidential objects remain in #{legacy} with no copy in #{target} " \
         '(the other environment\'s files, or orphans no row refers to).'
    puts "  #{kept.first(20).join("\n  ")}" if kept.any?
    puts 'Dry run only. Re-run with CONFIRM=purge to delete.' unless delete
  end
end
