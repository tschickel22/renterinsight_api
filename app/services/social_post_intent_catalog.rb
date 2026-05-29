# frozen_string_literal: true

# Industry-aware catalog of social-post "intents" (content angles).
#
# Each company.industry maps to a *family* of behavior:
#   :dealer  -> manufactured_housing, rv     (inventory-centric — original behavior, preserved verbatim)
#   :saas    -> saas                          (product/feature-centric)
#   :generic -> property_management, storage, other / anything else
#
# A profile defines the system-prompt persona, the compliance line (if any),
# the ordered intent set, the default rotation for new schedules, and the
# label used when referring to the "thing" a post is about.
#
# `requires_subject` means the intent expects a concrete inventory item
# (a vehicle/unit). Only the :dealer family has a vehicle model, so non-dealer
# intents never require a subject.
module SocialPostIntentCatalog
  # instruction may be a String, or a Proc taking the generation ctx (for the
  # few intents that interpolate runtime values like days-in-stock).
  Intent = Struct.new(:value, :label, :cta, :requires_subject, :instruction, keyword_init: true)

  Profile = Struct.new(:family, :persona, :compliance, :subject_label, :default_rotation, :intents, keyword_init: true) do
    def intent(value)
      intents.find { |i| i.value == value.to_s }
    end

    def intent_values
      intents.map(&:value)
    end

    def requires_subject?(value)
      i = intent(value)
      i ? i.requires_subject : false
    end
  end

  module_function

  def family_for(industry)
    case industry.to_s
    when 'manufactured_housing', 'rv' then :dealer
    when 'saas'                       then :saas
    else                                   :generic
    end
  end

  def for_industry(industry)
    PROFILES.fetch(family_for(industry))
  end

  def for_company(company)
    for_industry(company&.try(:industry))
  end

  # ------------------------------------------------------------------
  # DEALER family (manufactured_housing, rv) — original behavior verbatim
  # ------------------------------------------------------------------
  DEALER = Profile.new(
    family: :dealer,
    persona: 'You are a social media expert for manufactured housing and RV dealerships. ' \
             'Write content that is warm, local, compliant, and conversion-oriented.',
    compliance: 'Compliance: whenever price appears, append "Subject to change. See dealer for details." to the description.',
    subject_label: 'unit',
    default_rotation: %w[new_arrival specific_unit education social_proof lifestyle],
    intents: [
      Intent.new(value: 'specific_unit', label: 'Specific Unit', cta: 'shop_now', requires_subject: true,
                 instruction: 'Write a social post that features THIS specific home. Lead with the year/make/model, call out bedrooms/bathrooms, price, and photo-worthy feature. CTA = shop_now.'),
      Intent.new(value: 'price_drop', label: 'Price Drop', cta: 'shop_now', requires_subject: true,
                 instruction: 'Write a short, urgent social post about a price reduction on this home. Use a clear before/after framing if possible, otherwise emphasize that the price just dropped. CTA = shop_now.'),
      Intent.new(value: 'social_proof', label: 'Social Proof', cta: 'message_us', requires_subject: false,
                 instruction: "Write a celebration post about a family getting into their new home. Keep the home specifics light; lead with the feeling of 'welcome home'. CTA = message_us."),
      Intent.new(value: 'education', label: 'Education', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write an educational post about the benefits of manufactured housing (affordability, customization, speed, energy efficiency, quality). Do NOT hard-sell a specific unit. CTA = learn_more.'),
      Intent.new(value: 'financing', label: 'Financing', cta: 'apply_now', requires_subject: false,
                 instruction: 'Write an accessible, non-intimidating post about financing options (programs for first-time buyers, land-home, etc.). Avoid rate promises. CTA = apply_now.'),
      Intent.new(value: 'lifestyle', label: 'Lifestyle', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a lifestyle / community post centered on life in the area (schools, parks, outdoors). Soft tie-in to the dealership. CTA = learn_more.'),
      Intent.new(value: 'seasonal', label: 'Seasonal', cta: 'shop_now', requires_subject: false,
                 instruction: 'Write a seasonal promotion post tied to current season/holiday. Emphasize timing without being gimmicky. CTA = shop_now.'),
      Intent.new(value: 'rep_personal', label: 'Rep Personal', cta: 'message_us', requires_subject: false,
                 instruction: "Write a personal-voice post from a single sales rep's perspective. First person, conversational, warm. Mention one concrete thing happening at the lot this week. CTA = message_us."),
      Intent.new(value: 'new_arrival', label: 'New Arrival', cta: 'shop_now', requires_subject: true,
                 instruction: "Write a 'just arrived' announcement. Lead with the newness. If a unit is provided, showcase it. CTA = shop_now."),
      Intent.new(value: 'aged_inventory', label: 'Aged Inventory', cta: 'message_us', requires_subject: true,
                 instruction: ->(ctx) {
                   dwell = ctx.dig(:vehicle, :days_in_stock)
                   "Write a post that refreshes interest in a home that's been on the lot for #{dwell || '60+'} days. Re-frame it as an opportunity (well-kept, ready-to-move, price negotiation possible). CTA = message_us."
                 }),
      Intent.new(value: 'ad_content', label: 'Ad Content', cta: 'shop_now', requires_subject: true,
                 instruction: <<~AD.strip),
                   Generate Facebook/Instagram ad content for this unit. Produce three ad fields:
                   1. PRIMARY TEXT  — the main ad copy, 125 characters max for best performance. Put this in `caption`.
                   2. HEADLINE      — 40 characters max, shown below the image. Put this in `headline`.
                   3. DESCRIPTION   — 30 characters max, shown below the headline. Put this in `description`.
                   CTA should be `lead_generation` or `shop_now`. Hashtags optional (≤3).
                   Stay punchy; do not exceed the character limits.
                 AD
    ]
  )

  # ------------------------------------------------------------------
  # SAAS family — product/feature-centric
  # ------------------------------------------------------------------
  SAAS = Profile.new(
    family: :saas,
    persona: 'You are a B2B SaaS social media marketer. Write content that is clear, credible, ' \
             'value-driven, and speaks to the outcomes customers achieve with the product. ' \
             'Lean on the business context (products/services, value proposition, target audience) provided below.',
    compliance: nil,
    subject_label: 'product or feature',
    default_rotation: %w[feature_spotlight customer_win product_education new_release thought_leadership],
    intents: [
      Intent.new(value: 'feature_spotlight', label: 'Feature Spotlight', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a post that spotlights a specific product capability. Lead with the customer pain it removes, then the capability, then the outcome. Concrete over abstract. CTA = learn_more.'),
      Intent.new(value: 'new_release', label: 'New Release', cta: 'learn_more', requires_subject: false,
                 instruction: "Write a 'just shipped' announcement for a new product, feature, or update. Lead with what's new and why it matters to users. Keep it crisp and excited without hype. CTA = learn_more."),
      Intent.new(value: 'customer_win', label: 'Customer Win', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a customer-success / social-proof post about how a client wins with the product (a result, metric, or before/after). Keep names generic unless provided. Lead with the outcome. CTA = learn_more.'),
      Intent.new(value: 'product_education', label: 'Product Education', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write an educational, how-to post that teaches the audience something useful related to the product space. Do NOT hard-sell. Deliver value first. CTA = learn_more.'),
      Intent.new(value: 'thought_leadership', label: 'Thought Leadership', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a thought-leadership post sharing a point of view on an industry trend or problem the target audience cares about. Credible, specific, opinionated. Soft tie-in to the product. CTA = learn_more.'),
      Intent.new(value: 'integration', label: 'Integration / Partnership', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a post highlighting an integration or partnership and the workflow it unlocks for users. Focus on the combined value. CTA = learn_more.'),
      Intent.new(value: 'promotion', label: 'Promotion / Trial', cta: 'shop_now', requires_subject: false,
                 instruction: 'Write a promotional post inviting the audience to start a trial, demo, or limited-time offer. Clear value, clear next step, low friction. CTA = shop_now.'),
      Intent.new(value: 'seasonal', label: 'Seasonal', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a seasonal / timely post that ties the product to the current season, quarter, or industry moment. Relevant, not gimmicky. CTA = learn_more.'),
      Intent.new(value: 'ad_content', label: 'Ad Content', cta: 'shop_now', requires_subject: false,
                 instruction: <<~AD.strip),
                   Generate Facebook/Instagram ad content for this product. Produce three ad fields:
                   1. PRIMARY TEXT  — the main ad copy, 125 characters max for best performance. Put this in `caption`.
                   2. HEADLINE      — 40 characters max, shown below the image. Put this in `headline`.
                   3. DESCRIPTION   — 30 characters max, shown below the headline. Put this in `description`.
                   CTA should be `lead_generation` or `shop_now`. Hashtags optional (≤3).
                   Stay punchy; do not exceed the character limits.
                 AD
    ]
  )

  # ------------------------------------------------------------------
  # GENERIC family — property_management, storage, other businesses
  # ------------------------------------------------------------------
  GENERIC = Profile.new(
    family: :generic,
    persona: 'You are a social media marketer for a local service business. Write content that is ' \
             'warm, helpful, locally relevant, and conversion-oriented. Lean on the business context ' \
             '(products/services, value proposition, target audience) provided below.',
    compliance: nil,
    subject_label: 'offering',
    default_rotation: %w[announcement social_proof education promotion seasonal],
    intents: [
      Intent.new(value: 'announcement', label: 'Announcement', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write an announcement post about something new or noteworthy at the business. Lead with what it is and why it matters to customers. CTA = learn_more.'),
      Intent.new(value: 'social_proof', label: 'Social Proof', cta: 'message_us', requires_subject: false,
                 instruction: 'Write a social-proof post — a happy customer, a review highlight, or a community win. Lead with the human outcome. CTA = message_us.'),
      Intent.new(value: 'education', label: 'Education', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write an educational post that teaches the audience something useful related to the business. Deliver value first; do NOT hard-sell. CTA = learn_more.'),
      Intent.new(value: 'promotion', label: 'Promotion', cta: 'shop_now', requires_subject: false,
                 instruction: 'Write a promotional post about a current offer, opening, or availability. Clear value and a clear next step. CTA = shop_now.'),
      Intent.new(value: 'seasonal', label: 'Seasonal', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a seasonal / timely post tied to the current season or local moment. Relevant, not gimmicky. CTA = learn_more.'),
      Intent.new(value: 'lifestyle', label: 'Community / Lifestyle', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a community / lifestyle post centered on life in the area and the role the business plays in it. Soft tie-in. CTA = learn_more.'),
      Intent.new(value: 'feature_spotlight', label: 'Service Spotlight', cta: 'learn_more', requires_subject: false,
                 instruction: 'Write a post spotlighting a specific service or offering. Lead with the customer need it meets, then the offering, then the benefit. CTA = learn_more.'),
      Intent.new(value: 'ad_content', label: 'Ad Content', cta: 'shop_now', requires_subject: false,
                 instruction: <<~AD.strip),
                   Generate Facebook/Instagram ad content for this business. Produce three ad fields:
                   1. PRIMARY TEXT  — the main ad copy, 125 characters max for best performance. Put this in `caption`.
                   2. HEADLINE      — 40 characters max, shown below the image. Put this in `headline`.
                   3. DESCRIPTION   — 30 characters max, shown below the headline. Put this in `description`.
                   CTA should be `lead_generation` or `shop_now`. Hashtags optional (≤3).
                   Stay punchy; do not exceed the character limits.
                 AD
    ]
  )

  PROFILES = {
    dealer:  DEALER,
    saas:    SAAS,
    generic: GENERIC
  }.freeze
end
