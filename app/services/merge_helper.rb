# frozen_string_literal: true

# MergeHelper applies an incoming hash of attributes to an existing record
# WITHOUT destroying data. The rule: only fill attributes that are currently
# blank on the record. If the record already has a non-blank value that differs
# from the incoming value, that difference is recorded as a "conflict" and the
# existing value is left untouched.
#
# This is the safe default for absorbing a duplicate intake submission into an
# existing lead: we enrich empty fields, never overwrite good data, and surface
# anything that disagreed so a human can reconcile it from the logged note.
#
# Usage:
#   result = MergeHelper.fill_empty(lead, { phone: '...', city: '...' })
#   result[:applied]   => { 'city' => '...' }            (what we actually set)
#   result[:conflicts] => [{ field:, existing:, incoming: }]
#   lead.save! if result[:applied].any?
module MergeHelper
  module_function

  # @param record [ActiveRecord::Base] the record to enrich (NOT saved here)
  # @param incoming [Hash] attribute_name => value (string or symbol keys)
  # @param only [Array<Symbol>, nil] optional whitelist of attributes to consider
  # @return [Hash] { applied: {field=>value}, conflicts: [{field:,existing:,incoming:}], skipped: [...] }
  def fill_empty(record, incoming, only: nil)
    applied   = {}
    conflicts = []
    skipped   = []

    incoming.each do |key, raw_value|
      attr = key.to_s
      next if raw_value.nil?
      value = raw_value.is_a?(String) ? raw_value.strip : raw_value
      next if value.respond_to?(:empty?) && value.empty?

      # Only touch real, writable columns on this record.
      next unless record.respond_to?("#{attr}=") && record.respond_to?(attr)
      next if only && !only.map(&:to_s).include?(attr)

      existing = record.public_send(attr)

      # A JSONB bag (custom_field_values) holds many answers, not one value.
      # Treated as a single attribute, a lead that already had ANY custom
      # answer counted as "not blank", so every custom answer on a repeat
      # submission was reported as one whole-hash conflict and dropped. Merge
      # key by key under the same fill-empty rule instead.
      if existing.is_a?(Hash) && value.is_a?(Hash)
        merged = existing.dup
        touched = false

        value.each do |sub_key, sub_value|
          next if sub_value.nil? || (sub_value.respond_to?(:empty?) && sub_value.empty?)
          k = sub_key.to_s

          if merged[k].blank?
            merged[k] = sub_value
            applied[k] = sub_value
            touched = true
          elsif normalize(merged[k]) != normalize(sub_value)
            conflicts << { field: k, existing: merged[k], incoming: sub_value }
          else
            skipped << k
          end
        end

        record.public_send("#{attr}=", merged) if touched
        next
      end

      if existing.blank?
        record.public_send("#{attr}=", value)
        applied[attr] = value
      elsif normalize(existing) != normalize(value)
        conflicts << { field: attr, existing: existing, incoming: value }
      else
        skipped << attr # same value, nothing to do
      end
    end

    { applied: applied, conflicts: conflicts, skipped: skipped }
  end

  # Render conflicts as a human-readable block for appending to a Note.
  # Returns nil when there are no conflicts.
  def conflicts_note(conflicts)
    return nil if conflicts.blank?

    lines = ["\u26A0\uFE0F CONFLICTING VALUES (kept existing, did not overwrite):"]
    conflicts.each do |c|
      lines << "  • #{c[:field].to_s.humanize}: kept \"#{c[:existing]}\" — new submission had \"#{c[:incoming]}\""
    end
    lines.join("\n")
  end

  def normalize(val)
    val.to_s.strip.downcase
  end
end
