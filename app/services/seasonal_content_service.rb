# frozen_string_literal: true

# Provides seasonal / holiday content suggestions for the Social Post
# auto-scheduling engine and the frontend suggestion cards.
#
# Usage:
#   SeasonalContentService.current_suggestions    # → array of matching entries
#   SeasonalContentService.topic_for_seasonal_post # → random topic string or nil
#
class SeasonalContentService
  Entry = Struct.new(:month, :day_start, :day_end, :name, :intent, :topic, :icon, keyword_init: true)

  SEASONAL_CALENDAR = [
    Entry.new(month: 1,  day_start: 1,  day_end: 15, name: 'New Year Savings',        intent: 'seasonal',     icon: "\u{1F389}", topic: 'New Year, new home! Kick off the year with special savings on select homes. Fresh start, fresh space.'),
    Entry.new(month: 2,  day_start: 1,  day_end: 14, name: "Valentine's Day",          intent: 'lifestyle',    icon: "\u{2764}\u{FE0F}", topic: "Fall in love with your dream home this Valentine's season. Tour our move-in ready homes this weekend."),
    Entry.new(month: 2,  day_start: 15, day_end: 28, name: 'Presidents Day Sale',      intent: 'seasonal',     icon: "\u{1F1FA}\u{1F1F8}", topic: 'Presidents Day weekend sale — special pricing on select inventory. Limited time.'),
    Entry.new(month: 3,  day_start: 1,  day_end: 31, name: 'Spring Into a New Home',   intent: 'seasonal',     icon: "\u{1F338}", topic: 'Spring is the perfect time to make a move. New homes arriving weekly. Tour our latest models.'),
    Entry.new(month: 4,  day_start: 1,  day_end: 20, name: 'Easter / Spring Break',    intent: 'lifestyle',    icon: "\u{1F430}", topic: 'Spring break plans? How about planning your new home! Visit us this weekend for family-friendly tours.'),
    Entry.new(month: 4,  day_start: 15, day_end: 30, name: 'Earth Day / Green Living',  intent: 'education',   icon: "\u{1F30D}", topic: 'Did you know? Modern manufactured homes are built with energy-efficient materials and appliances. Go green, save money.'),
    Entry.new(month: 5,  day_start: 1,  day_end: 15, name: "Mother's Day",             intent: 'social_proof', icon: "\u{1F490}", topic: 'Give Mom the gift of space. Celebrate the moms who made a house a home. Share your story!'),
    Entry.new(month: 5,  day_start: 20, day_end: 31, name: 'Memorial Day Sale',        intent: 'seasonal',     icon: "\u{1F1FA}\u{1F1F8}", topic: 'Memorial Day weekend deals — special financing and savings on select homes. This weekend only.'),
    Entry.new(month: 6,  day_start: 1,  day_end: 30, name: 'Summer Move-In',           intent: 'specific_unit', icon: "\u{2600}\u{FE0F}", topic: 'Summer is here! Move in before school starts. We have homes ready for immediate delivery.'),
    Entry.new(month: 6,  day_start: 10, day_end: 20, name: "Father's Day",             intent: 'social_proof', icon: "\u{1F454}", topic: "Happy Father's Day! To the dads building a future for their families — we're here to help."),
    Entry.new(month: 7,  day_start: 1,  day_end: 7,  name: '4th of July',              intent: 'seasonal',     icon: "\u{1F386}", topic: 'Celebrate freedom in a home of your own! Independence Day specials happening now.'),
    Entry.new(month: 7,  day_start: 8,  day_end: 31, name: 'Mid-Year Clearance',       intent: 'price_drop',   icon: "\u{1F3F7}\u{FE0F}", topic: 'Mid-year clearance event — select homes at reduced prices. Make your move before fall.'),
    Entry.new(month: 8,  day_start: 1,  day_end: 31, name: 'Back to School',           intent: 'specific_unit', icon: "\u{1F4DA}", topic: 'Get settled before school starts! Family-friendly homes with room for everyone. Tour this weekend.'),
    Entry.new(month: 9,  day_start: 1,  day_end: 7,  name: 'Labor Day Sale',           intent: 'seasonal',     icon: "\u{1F528}", topic: 'Labor Day weekend event — special pricing, financing incentives, and move-in ready homes.'),
    Entry.new(month: 9,  day_start: 8,  day_end: 30, name: 'Fall Into Savings',        intent: 'seasonal',     icon: "\u{1F342}", topic: 'Fall into your new home. Cozy up this season with our latest move-in ready models.'),
    Entry.new(month: 10, day_start: 1,  day_end: 31, name: 'Harvest / Halloween',      intent: 'lifestyle',    icon: "\u{1F383}", topic: 'Imagine trick-or-treating from your own front door. Make this the year you move in!'),
    Entry.new(month: 11, day_start: 1,  day_end: 15, name: 'Veterans Day',             intent: 'financing',    icon: "\u{1F396}\u{FE0F}", topic: 'Thank you to our veterans. Ask about VA loan programs and special financing for military families.'),
    Entry.new(month: 11, day_start: 20, day_end: 30, name: 'Black Friday / Thanksgiving', intent: 'seasonal',  icon: "\u{1F983}", topic: 'Thankful for a place to call home. Black Friday deals on select homes — biggest savings of the year.'),
    Entry.new(month: 12, day_start: 1,  day_end: 25, name: 'Holiday Season',           intent: 'lifestyle',    icon: "\u{1F384}", topic: "Home for the holidays — there's nothing like it. Tour our decorated model homes this weekend."),
    Entry.new(month: 12, day_start: 26, day_end: 31, name: 'Year-End Clearance',       intent: 'price_drop',   icon: "\u{1F38A}", topic: 'Year-end clearance! We are making room for new inventory. Best prices of the year on remaining homes.'),
  ].freeze

  class << self
    # Returns all calendar entries whose window covers today.
    def current_suggestions
      today = Date.current
      SEASONAL_CALENDAR.select do |e|
        e.month == today.month && today.day >= e.day_start && today.day <= e.day_end
      end
    end

    # Picks a random topic string for the current season, or nil if nothing matches.
    def topic_for_seasonal_post
      entries = current_suggestions
      entries.any? ? entries.sample.topic : nil
    end

    # Returns the full calendar for frontend rendering.
    def full_calendar
      SEASONAL_CALENDAR.map do |e|
        {
          month: e.month,
          day_start: e.day_start,
          day_end: e.day_end,
          name: e.name,
          intent: e.intent,
          topic: e.topic,
          icon: e.icon
        }
      end
    end
  end
end
