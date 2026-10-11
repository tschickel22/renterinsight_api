# frozen_string_literal: true

module Guide
  # Questions the help could not answer (backlog E75, phase 7): searches that
  # found nothing and assistant questions it said it did not know, grouped so
  # the most asked come first. Each can be sent to the release queue to have
  # an article drafted for it.
  class Gaps
    WINDOW = 60.days

    def self.list(limit: 50)
      rows = Knowledge::Search.where(result_count: 0).where('created_at > ?', WINDOW.ago)
                              .where.not(query: [nil, ''])
                              .pluck(:query, :created_at, :action_taken)
      queued = Knowledge::ChangeQueueItem.where(entity_type: 'gap').pluck(:entity_key).to_set

      rows.group_by { |q, _, _| normalize(q) }
          .reject { |key, _| key.length < 3 }
          .map do |key, group|
            {
              key: key, question: group.max_by { |_, at, _| at }.first, asked: group.size,
              last_asked_at: group.map { |_, at, _| at }.max,
              from_assistant: group.any? { |_, _, action| action == 'assistant' },
              queued: queued.include?(key)
            }
          end
          .sort_by { |g| [-g[:asked], -g[:last_asked_at].to_i] }
          .first(limit)
    end

    def self.normalize(query)
      query.to_s.downcase.gsub(/[^a-z0-9& ]/, ' ').squish
    end

    # Queue a draft article for a gap, reviewed in the Releases tab like any
    # other draft.
    def self.queue!(question)
      key = normalize(question)
      existing = Knowledge::ChangeQueueItem.find_by(entity_type: 'gap', entity_key: key)
      return existing if existing

      snapshot = Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE).order(snapshot_at: :desc).first
      raise ArgumentError, 'No feature map yet; the release watcher has not read a build.' unless snapshot

      item = snapshot.change_queue_items.create!(
        change_type: 'added', entity_type: 'gap', entity_key: key,
        new_value: { 'title' => question.to_s.first(200) }, context: { 'question' => question.to_s.first(500) }
      )
      Guide::DraftReleaseItemJob.perform_later(item.id)
      item
    end
  end
end
