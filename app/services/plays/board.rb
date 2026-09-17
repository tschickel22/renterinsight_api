# frozen_string_literal: true

module Plays
  # The journey board: everyone in a play that is on, in one place, in the
  # furthest column any of their plays has them in. Built for a trade show
  # screen as much as a desk.
  #
  # Read from each play's own lead list, so the board and the play pages never
  # disagree about where someone is.
  class Board
    COLUMNS = [
      { key: 'new', label: 'New lead' },
      # %{lead} is the dealer's own word: the play has sent its messages and it
      # is the lead's turn, not the rep's.
      { key: 'waiting', label: 'Waiting for the %{lead} to reply' },
      { key: 'follow_up', label: 'In follow-up' },
      { key: 'weekly', label: 'Weekly homes' },
      { key: 'talking', label: 'Talking' },
      { key: 'deal', label: 'Became a deal' },
      { key: 'sold', label: 'Sold' }
    ].freeze
    RANK = COLUMNS.each_with_index.to_h { |column, index| [column[:key], index] }.freeze

    # Each kind of play's stages, as board columns. A stage with no column
    # (stopped, unsubscribed, lost) leaves the person off the board for that play.
    STAGE_COLUMNS = {
      'lead_response' => { 'first_response' => 'new', 'waiting_for_reply' => 'waiting', 'replied' => 'talking',
                           'follow_up' => 'follow_up', 'follow_up_done' => 'follow_up', 'became_deal' => 'deal' },
      'landing_page' => { 'sent_form' => 'new', 'became_deal' => 'deal' },
      'recurring_email' => { 'subscribed' => 'weekly', 'became_deal' => 'deal' },
      'reengagement' => { 'in_sequence' => 'follow_up', 'woke_up' => 'talking', 'became_deal' => 'deal' },
      'deal_followup' => { 'in_pipeline' => 'deal', 'after_sale' => 'sold', 'after_sale_done' => 'sold' }
    }.freeze

    PER_PLAY = 100

    def initialize(company:, location_ids: nil)
      @company = company
      @location_ids = location_ids
    end

    def call
      active = PlayInstallation.active.where(company_id: @company.id).index_by(&:play_key)
      cards = {}

      Registry.all_for(@company).each do |play|
        installation = active[play::KEY]
        columns = STAGE_COLUMNS[play.kind]
        next unless installation && columns

        rows = play.leads_for(installation, period: 'all', location_ids: @location_ids, stage: nil, page: 1, per_page: PER_PLAY)[:items]
        rows.each do |row|
          column = columns[row[:stage].to_s]
          next unless column

          card = card_for(play, row, column)
          current = cards[card[:id]]
          cards[card[:id]] = card if current.nil? || further?(card, current)
        end
      end

      list = cards.values.sort_by { |card| card[:started_at].to_s }.reverse
      {
        columns: COLUMNS.map do |column|
          column.merge(label: format(column[:label], lead: lead_word), count: list.count { |card| card[:column] == column[:key] })
        end,
        cards: list,
        demo_clock: { available: DemoClock.available?(@company), enabled: DemoClock.enabled?(@company) },
        updated_at: Time.current.iso8601
      }
    end

    private

    def lead_word
      @lead_word ||= (@company.resolved_labels['lead'].presence || 'lead').downcase
    end

    def card_for(play, row, column)
      deal = play.kind == 'deal_followup'
      {
        id: "#{deal ? 'deal' : 'lead'}:#{row[:lead_id]}",
        record_id: row[:lead_id],
        record_noun: deal ? 'deal' : 'lead',
        name: row[:name],
        column: column,
        play_key: play::KEY,
        play_name: play::NAME,
        stage_label: row[:stage_label],
        detail: row[:detail],
        detail_at: row[:detail_at],
        started_at: row[:started_at]
      }
    end

    # Further along the board wins; in the same column, the more recent play.
    def further?(card, current)
      return RANK[card[:column]] > RANK[current[:column]] if RANK[card[:column]] != RANK[current[:column]]

      card[:started_at].to_s > current[:started_at].to_s
    end
  end
end
