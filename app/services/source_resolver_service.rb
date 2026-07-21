# frozen_string_literal: true

# Resolves a Lead Source for inbound lead capture (intake forms, partner API
# webhooks, Zapier POSTs, etc.). Priority:
#
#   1. explicit source_id — trusts a numeric catalog reference, scoped to the
#      company. This is what the Share dialog puts in ?source_id=<id>.
#   2. source_name string — matches against the company Sources catalog:
#        a. exact (case + punctuation normalized)
#        b. substring in either direction
#        c. Levenshtein distance <= 2 (typo tolerance)
#      If no match at all, auto-creates a new Source with the exact string
#      the caller sent, tagged so the dealer can audit inbound-generated
#      sources in the Sources tab.
#   3. default_source_id — per-key default (webhook_config.default_source_id)
#      or per-form default (intake_form.source_id).
#   4. hard fallback — a company-scoped "Web Form" Source, created on demand
#      so no lead is ever sourceless (nil source_id hides leads from some
#      reports and breaks attribution).
#
# Returns the resolved Source (never nil unless the company is missing).
class SourceResolverService
  FALLBACK_NAME = 'Web Form'
  AUTO_CREATE_TAG = 'inbound_webhook'
  LEVENSHTEIN_THRESHOLD = 2

  def self.resolve(company:, source_id: nil, source_name: nil, default_source_id: nil)
    new(company: company, source_id: source_id, source_name: source_name, default_source_id: default_source_id).resolve
  end

  def initialize(company:, source_id:, source_name:, default_source_id:)
    @company = company
    @source_id = source_id.presence
    @source_name = source_name.to_s.strip.presence
    @default_source_id = default_source_id.presence
  end

  def resolve
    return nil unless @company

    resolved_by_id || resolved_by_name || resolved_by_default || fallback
  end

  private

  attr_reader :company

  def resolved_by_id
    return nil unless @source_id
    company.sources.where(id: @source_id.to_i).first
  end

  def resolved_by_name
    return nil unless @source_name

    match = exact_match(@source_name) ||
            substring_match(@source_name) ||
            levenshtein_match(@source_name)
    return match if match

    auto_create_source(@source_name)
  end

  def resolved_by_default
    return nil unless @default_source_id
    company.sources.where(id: @default_source_id.to_i).first
  end

  def fallback
    company.sources.find_or_create_by(name: FALLBACK_NAME) do |src|
      src.is_active = true
    end
  end

  # ── Matching strategies ──────────────────────────────────────────────

  def exact_match(name)
    normalized = normalize(name)
    company.sources.active.find { |s| normalize(s.name) == normalized }
  end

  def substring_match(name)
    normalized = normalize(name)
    return nil if normalized.length < 3 # avoid trivial matches on 1-2 char names

    company.sources.active.find do |s|
      other = normalize(s.name)
      next false if other.length < 3
      other.include?(normalized) || normalized.include?(other)
    end
  end

  def levenshtein_match(name)
    normalized = normalize(name)
    best = nil
    best_distance = LEVENSHTEIN_THRESHOLD + 1

    company.sources.active.each do |s|
      d = levenshtein(normalized, normalize(s.name))
      if d < best_distance
        best_distance = d
        best = s
      end
    end

    best_distance <= LEVENSHTEIN_THRESHOLD ? best : nil
  end

  def auto_create_source(name)
    src = company.sources.new(name: name.to_s.strip[0, 100], is_active: true)
    if src.respond_to?(:metadata=)
      src.metadata = { auto_created_via: AUTO_CREATE_TAG, first_seen_at: Time.current.iso8601 }
    end
    src.save
    src.persisted? ? src : nil
  end

  def normalize(str)
    str.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # Iterative Levenshtein — Ruby stdlib doesn't ship one, and pulling in a gem
  # for a two-loop function is overkill.
  def levenshtein(a, b)
    return b.length if a.empty?
    return a.length if b.empty?

    m = a.length
    n = b.length
    prev = (0..n).to_a
    curr = Array.new(n + 1)

    (1..m).each do |i|
      curr[0] = i
      (1..n).each do |j|
        cost = a[i - 1] == b[j - 1] ? 0 : 1
        curr[j] = [
          curr[j - 1] + 1,      # insertion
          prev[j] + 1,          # deletion
          prev[j - 1] + cost    # substitution
        ].min
      end
      prev = curr.dup
    end

    prev[n]
  end
end
