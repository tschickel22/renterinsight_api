# frozen_string_literal: true

# Find & merge duplicates, shared by the Lead, Contact and Account controllers.
#
# Three endpoints, matching how every CRM does this:
#   GET  .../:id/duplicates      what looks like the same record
#   POST .../:id/merge_preview   exactly what a merge would do, changes nothing
#   POST .../:id/merge           do it
#
# The :id in the path is always the SURVIVOR. The record being merged away is
# named in the body as duplicate_id, so a mis-sent request cannot silently
# retire the record the user is looking at.
module MergeableRecords
  extend ActiveSupport::Concern

  def duplicates
    return unless authorize_action!(merge_resource_key, 'read')

    record = find_mergeable!(params[:id])
    return if performed?

    candidates = Merge::DuplicateFinder.call(record: record, company: @company)

    render json: {
      record: merge_identity(record),
      duplicates: candidates.map { |c|
        {
          **merge_identity(c.record),
          score: c.score,
          reasons: c.reasons,
          strong_match: c.strong,
          differing_fields: differing_fields(record, c.record)
        }
      }
    }
  end

  def merge_preview
    return unless authorize_action!(merge_resource_key, 'update')

    run_merge(preview: true)
  end

  def merge
    # 'update', not 'delete', and the choice is deliberate. Legacy authorization
    # maps delete to admin only, so requiring it would put duplicate cleanup out
    # of reach of the reps who actually notice duplicates. The merge is also
    # non-destructive: the duplicate keeps every one of its own values and is
    # only marked merged_into_id, so a mistake is recoverable. Salesforce gates
    # merge on delete; HubSpot gates it on edit. This follows HubSpot because
    # nothing here is actually deleted.
    return unless authorize_action!(merge_resource_key, 'update')

    run_merge(preview: false)
  end

  private

  def run_merge(preview:)
    survivor = find_mergeable!(params[:id])
    return if performed?

    duplicate = find_mergeable!(params[:duplicate_id])
    return if performed?

    result = Merge::RecordMerger.call(
      survivor: survivor,
      loser: duplicate,
      actor: current_user,
      field_overrides: params[:field_overrides]&.to_unsafe_h,
      preview: preview
    )

    render json: {
      preview: preview,
      survivor: merge_identity(result.survivor.reload),
      merged: merge_identity(result.merged),
      moved: result.moved,
      fields_taken: result.fields_taken,
      warnings: result.warnings,
      total_records_moved: result.moved.values.sum
    }
  rescue Merge::RecordMerger::MergeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Always through @company, never Model.find: a merge rewrites foreign keys
  # across dozens of tables, so an unscoped lookup here would be the worst
  # possible place for the company_id bug.
  def find_mergeable!(id)
    if id.blank?
      render json: { error: 'duplicate_id is required' }, status: :bad_request
      return nil
    end

    @company.public_send(merge_model_class.name.tableize).not_merged.find(id)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
    nil
  end

  # Which columns actually disagree, so the UI can show a field picker for just
  # those instead of every column on the table.
  def differing_fields(a, b)
    skip = Merge::RecordMerger::BOOKKEEPING
    (a.class.column_names - skip).filter_map do |col|
      av = a[col]
      bv = b[col]
      next if av.to_s == bv.to_s

      { field: col, survivor_value: av, duplicate_value: bv }
    end
  end

  def merge_identity(r)
    {
      id: r.id,
      name: merge_display_name(r),
      email: r.try(:email),
      phone: r.try(:phone),
      created_at: r.created_at,
      merged_into_id: r.merged_into_id
    }
  end

  def merge_display_name(r)
    return r.name if r.respond_to?(:name) && r.name.present?

    [r.try(:first_name), r.try(:last_name)].compact.join(' ').presence || "##{r.id}"
  end
end
