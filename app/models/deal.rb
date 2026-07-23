class Deal < ApplicationRecord
  include ActivityTrackable
  include Addressable
  include Buyable
  include LocationAware
  include NotifiableDeal
  include WebhookNotifiable
  include Reportable
  include WorkflowRunCancellable

  def self.reportable_config
    {
      label: "Deals",
      category: "crm",
      fields: [
        { key: "id",                  label: "ID",                  type: "number",  filterable: true,  sortable: true  },
        { key: "deal_number",         label: "Deal Number",         type: "string",  filterable: true,  sortable: true  },
        { key: "name",                label: "Title",               type: "string",  filterable: true,  sortable: true  },
        { key: "stage",               label: "Stage",               type: "enum",    filterable: true,  sortable: true  },
        { key: "value",               label: "Value",               type: "number",  filterable: true,  sortable: true  },
        { key: "selling_price",       label: "Selling Price",       type: "number",  filterable: true,  sortable: true  },
        { key: "probability",         label: "Probability (%)",     type: "number",  filterable: true,  sortable: true  },
        { key: "customer_name",       label: "Customer",            type: "string",  filterable: true,  sortable: true  },
        { key: "owner_id",            label: "Assigned To",         type: "number",  filterable: true,  sortable: true,  resolve_as: :user    },
        { key: "account_id",          label: "Account",             type: "number",  filterable: true,  sortable: true,  resolve_as: :account },
        { key: "contact_id",          label: "Contact",             type: "number",  filterable: true,  sortable: true,  resolve_as: :contact },
        { key: "expected_close_date", label: "Expected Close Date", type: "date",    filterable: true,  sortable: true  },
        { key: "actual_close_date",   label: "Actual Close Date",   type: "date",    filterable: true,  sortable: true  },
        { key: "won_at",              label: "Won At",              type: "date",    filterable: true,  sortable: true  },
        { key: "lost_at",             label: "Lost At",             type: "date",    filterable: true,  sortable: true  },
        { key: "win_reason",          label: "Win Reason",          type: "string",  filterable: false, sortable: false },
        { key: "loss_reason",         label: "Loss Reason",         type: "string",  filterable: false, sortable: false },
        { key: "created_at",          label: "Created At",          type: "date",    filterable: true,  sortable: true  },
        { key: "updated_at",          label: "Updated At",          type: "date",    filterable: true,  sortable: true  }
      ]
    }
  end

  belongs_to :company, optional: true
  belongs_to :location, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  # Co-applicant / co-borrower. A second Contact on the same account, created by
  # lead conversion from the lead's co_applicant_* fields. The Contact stays the
  # source of truth — the deal only points at it.
  belongs_to :co_applicant_contact, class_name: 'Contact', optional: true
  belongs_to :user, optional: true  # FIX: Made optional to prevent 422 errors when user_id not set
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  belongs_to :territory, optional: true
  belongs_to :source, optional: true
  belongs_to :vehicle, optional: true  # Added vehicle relationship
  belongs_to :lender, optional: true  # Managed lender list (denormalized to lender_name below)
  belongs_to :commission_plan, optional: true  # Commission plan for this deal
  belongs_to :deal_invoice, class_name: 'Invoice', optional: true
  
  # Deal participants for commission calculation
  belongs_to :primary_salesperson, class_name: 'User', foreign_key: 'primary_salesperson_id', optional: true
  belongs_to :sales_manager, class_name: 'User', foreign_key: 'sales_manager_id', optional: true
  belongs_to :finance_manager, class_name: 'User', foreign_key: 'finance_manager_id', optional: true
  belongs_to :desk_manager, class_name: 'User', foreign_key: 'desk_manager_id', optional: true
  belongs_to :secondary_salesperson, class_name: 'User', foreign_key: 'secondary_salesperson_id', optional: true
  
  has_many :deal_products, dependent: :destroy
  has_many :deal_desk_scenarios, dependent: :destroy
  has_many :invoices, dependent: :nullify
  has_many :deal_stage_histories, dependent: :destroy
  has_many :approval_workflows, dependent: :destroy
  has_one :win_loss_report, dependent: :destroy
  has_many :activities, class_name: 'DealActivity', dependent: :destroy
  has_many :commission_payments, dependent: :destroy
  has_many :quotes, dependent: :nullify
  has_many :service_tickets, dependent: :nullify
  has_one :project, dependent: :nullify

  # Tags (polymorphic association)
  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
  
  # Owner helper methods
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end
  
  validates :name, presence: true
  validates :value, numericality: { greater_than_or_equal_to: 0 }
  validates :probability, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validate :stage_is_valid

  def stage_is_valid
    return if stage.blank?
    # Company is the single source of truth for valid stages (saved override
    # or system default). Without a company we can't validate, so allow it.
    return unless company
    unless company.valid_pipeline_stage?(stage)
      errors.add(:stage, "#{stage} is not a valid stage")
    end
  end
  
  # Ensure at least account or contact is present
  validate :account_or_contact_required

  # The co-applicant is now settable from the deal page (not just at conversion),
  # so guard the three ways a picker can go wrong: another tenant's contact, the
  # primary applicant listed as their own co-applicant, or someone who isn't on
  # this deal's account.
  validate :co_applicant_contact_is_valid

  # Auto-generate deal number on creation
  before_create :generate_deal_number

  # Normalize stage to lowercase before validation
  before_validation :normalize_stage

  # Probability is derived from the stage (the configured stage's win-%), never
  # user-entered. Mirror it whenever the stage is set/changed so every path —
  # inline edit, deal form, board drag, convert, import — stays consistent.
  before_validation :sync_probability_from_stage, if: -> { new_record? || stage_changed? }

  def sync_probability_from_stage
    return unless company
    prob = company.pipeline_stage_probability(stage)
    self.probability = prob unless prob.nil?
  end
  
  # Sync primary_salesperson_id with owner_id for commission system
  before_validation :sync_primary_salesperson
  
  # Auto-assign commission plan based on salesperson/role/company default
  before_validation :auto_assign_commission_plan, if: -> { commission_plan_id.nil? && primary_salesperson_id.present? }
  
  # Sync vehicle pricing when vehicle is assigned
  before_validation :sync_vehicle_pricing, if: :will_save_change_to_vehicle_id?

  # Denormalize the managed lender's name onto lender_name so the reports (which read
  # lender_name) keep working unchanged. before_save folds it into the same UPDATE — no
  # nested save / re-entrancy. Only fires when lender_id actually changes. When lender_id
  # is cleared we intentionally leave lender_name as last set (manual string still allowed).
  before_save :denormalize_lender_name, if: :will_save_change_to_lender_id?

  def denormalize_lender_name
    self.lender_name = lender&.name if lender_id.present?
  end

  # PRICE SOURCE OF TRUTH (Phase 2B): selling_price is a DERIVED MIRROR of the home
  # line item's price, never a free-typed input. Whenever the deal has a home line
  # item, selling_price = home_line_item_price (pre-tax: unit_price*qty - discount).
  # When there is NO home line (legacy/API deals), selling_price is left as-is so
  # those deals keep computing via the fallback — we never null it.
  #
  # selling_price keeps its historical meaning (HOME price only) — fees/accessories
  # stay separate line items. This is what lets deal_invoice_service /
  # deal_accounting_service / deal_desk_scenario keep working unchanged (Option B).
  # The all-lines total lives on line_items_price / the value column, not here.
  #
  # FREEZE AT CLOSE: once the deal is closed/posted, the mirror stops so editing a
  # line post-close does not move the closed deal's frozen home price (and thus its
  # GP). The closing save itself still mirrors (the deal was open before that save),
  # freezing the close-time home price into the column.
  #
  # Registered BEFORE apply_selected_scenario_on_close (so a Deal Desk on_close
  # write-back's scenario price still wins at close) and BEFORE
  # snapshot_landed_cost_on_close + the after_commit GL post, which read off it.
  before_save :mirror_selling_price_from_home_line

  # Deal Desk: in 'on_close' mode, write the selected scenario's structure back to the deal
  # automatically as part of the close save (before the GL post, an after_commit, reads it).
  # before_save so the figures fold into THIS UPDATE; the hook assigns only (no nested save).
  before_save :apply_selected_scenario_on_close,
              if: -> { will_save_change_to_stage? && stage_is_won? &&
                       company&.deal_desk_writeback_mode == 'on_close' }

  # Freeze the vehicle's then-current structured cost onto the deal at close, so GP/COGS
  # stop moving (read-through ends) and become auditable. before_save means it persists
  # in the closing UPDATE and runs BEFORE both the after_save commission generation and
  # the after_commit GL post — both of which read gross off the now-snapshotted cost.
  # Registered after apply_selected_scenario_on_close so a deal-desk write-back's
  # explicit home_cost wins; otherwise capture the live vehicle cost.
  before_save :snapshot_landed_cost_on_close,
              if: -> { will_save_change_to_stage? && stage_is_won? }

  def snapshot_landed_cost_on_close
    return if home_cost.present? && home_cost.to_f > 0 # respect explicit / deal-desk cost

    # Freeze the home LINE ITEM cost (mirrored onto unit_cost by the deal form) first —
    # that's the cost the rep actually entered for this deal. Only fall back to the
    # vehicle's structured cost when no line-item cost was provided.
    uc = unit_cost.to_f
    if uc > 0
      self.home_cost = uc
      return
    end

    vc = vehicle&.structured_cost
    self.home_cost = vc if vc.present?
  end

  # Commission payments are NOT generated at close. They are generated only AFTER the
  # deal is GL-approved (deal_approvals_controller#approve), so commissions can't become
  # payable before accounting signs off. Generating here would create pending payments
  # the moment a deal closes — the bug this gate prevents. See generate_commission_payments!
  # below, invoked from the approval flow.
  # Mirror the deal's lifecycle onto the linked vehicle: close_won → sold,
  # transition back out → revert to available (only if this deal owns the sale).
  after_save :sync_vehicle_sold_status, if: :saved_change_to_stage?
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_stage?
  # Deals queue for accountant approval by default. Auto-posting only fires when the
  # company opts in via AccountingSettings.auto_post_deals; otherwise the deal sits in
  # the Deal Approvals queue until reviewed.
  after_commit :auto_post_closing_to_accounting, on: [:create, :update], if: -> { saved_change_to_stage? && stage_is_won? && !gl_posted? }
  # When this deal closes won on a vehicle, every OTHER open deal on that same
  # vehicle just lost the home — notify each of those reps to choose a new one.
  # Fires on the closed_won transition whether closed via mark_as_won or a direct
  # stage update (just_closed_won? keys off saved_change_to_stage?).
  after_commit :notify_home_sold_other_deals, if: -> { just_closed_won? && vehicle_id.present? }

  def auto_post_closing_to_accounting
    settings = AccountingSettings.for_company(company)
    return unless settings.try(:auto_post_deals)

    result = Accounting::DealAccountingService.new(self).post_closing_entries!(user: try(:owner) || try(:user))
    # When auto-post is enabled the deal is GL-posted without going through the approval
    # controller, so generate commission payments here too once the post succeeds. Keeps
    # the gate consistent: commissions are generated on GL post, never merely on close.
    reload
    generate_commission_payments! if gl_posted?
  rescue => e
    Rails.logger.error("[AutoPost] Deal #{id} closing entries failed: #{e.message}")
  end
  
  def normalize_stage
    self.stage = stage&.downcase
  end
  
  def account_or_contact_required
    if account_id.blank? && contact_id.blank?
      errors.add(:base, "Deal must have either an account or a contact")
    end
  end

  def co_applicant_contact_is_valid
    return if co_applicant_contact_id.blank?

    if co_applicant_contact_id.to_s == contact_id.to_s
      errors.add(:co_applicant_contact_id, "can't be the same person as the primary applicant")
      return
    end

    candidate = Contact.find_by(id: co_applicant_contact_id)
    if candidate.nil? || candidate.company_id != company_id
      errors.add(:co_applicant_contact_id, 'must be a contact in this company')
      return
    end

    if account_id.present? && candidate.account_id.present? && candidate.account_id != account_id
      errors.add(:co_applicant_contact_id, "must be a contact on this deal's account")
    end
  end

  # Scopes
  scope :open, -> { where(stage: %w[prospecting qualification needs_analysis proposal negotiation closing]) }
  # Tenant-aware: pass the company so custom pipeline keys (e.g. 'won'/'lost'
  # at Evangeline) resolve correctly. Callers always have the company in scope.
  scope :won,  ->(company) { where(stage: company.won_stage_keys) }
  scope :lost, ->(company) { where(stage: company.lost_stage_keys) }
  scope :by_stage, ->(stage) { where(stage: stage&.downcase) }
  scope :by_territory, ->(territory_id) { where(territory_id: territory_id) }
  scope :by_owner, ->(user_id) { where(user_id: user_id) }
  scope :by_contact, ->(contact_id) { where(contact_id: contact_id) }
  scope :by_vehicle, ->(vehicle_id) { where(vehicle_id: vehicle_id) }
  scope :expected_to_close, ->(date) { where('expected_close_date <= ?', date) }
  scope :recently_created, -> { where('created_at >= ?', 30.days.ago) }
  scope :recently_won, -> { where('won_at >= ?', 30.days.ago) }
  scope :recently_lost, -> { where('lost_at >= ?', 30.days.ago) }
  
  # Soft delete
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  
  def soft_delete
    update(deleted_at: Time.current)
  end
  
  def restore
    update(deleted_at: nil)
  end
  
  # Stage management
  # Resolves the tenant's won/lost stage key from the company pipeline config,
  # so custom pipelines (e.g. Evangeline's 'won'/'lost') are written correctly
  # rather than being force-set to the canonical 'closed_won'.
  def mark_as_won(reason: nil)
    update(
      stage: company&.default_won_stage_key || 'closed_won',
      won_at: Time.current,
      actual_close_date: Date.today,
      win_reason: reason
    )
  end

  def mark_as_lost(reason: nil, competitor: nil)
    update(
      stage: company&.default_lost_stage_key || 'closed_lost',
      lost_at: Time.current,
      actual_close_date: Date.today,
      loss_reason: reason,
      competitor: competitor
    )
  end

  def closed?
    stage_is_won? || stage_is_lost?
  end

  # Predicates used by lifecycle callbacks; resolve against the tenant's
  # pipeline so custom keys still fire the correct hooks.
  def stage_is_won?
    company ? company.won_stage_keys.include?(stage.to_s) : stage == 'closed_won'
  end

  def stage_is_lost?
    company ? company.lost_stage_keys.include?(stage.to_s) : stage == 'closed_lost'
  end
  
  def open?
    !closed?
  end
  
  # Helper to get customer name from account or contact
  def customer_display_name
    # Prioritize manual customer_name field if set
    return customer_name if customer_name.present?
    
    # Otherwise, derive from account or contact
    if account
      account.name
    elsif contact
      "#{contact.first_name} #{contact.last_name}".strip
    else
      'Unknown'
    end
  end
  
  # Vehicle display helper
  def vehicle_display_name
    vehicle&.display_name
  end
  
  # ============================================================================
  # VALUE CALCULATIONS
  # ============================================================================
  
  # Calculate total deal value from line items (products).
  # If products exist, use their total. Otherwise fall back to selling_price or manual value.
  def calculated_value
    products_total = deal_products.sum(:total)
    if products_total > 0
      products_total.round(2)
    else
      (selling_price || value || 0).to_f.round(2)
    end
  end

  # ============================================================================
  # LINE-ITEM AS PRICE SOURCE — derivation methods (Phase 2A groundwork).
  #
  # READ-ONLY / ADDITIVE. These expose what the line items say about price and
  # cost so we can migrate selling_price → home line item later. They are NOT
  # wired into front_gross/landed_cost/value in this phase — front_gross stays
  # selling_price-based. The home line is a deal_product whose SKU is VEHICLE-<id>
  # (DealProduct::VEHICLE_SKU_PATTERN), tagged `category:home` by the backfill.
  # ============================================================================

  # The single home/unit line item, or nil when the home is not yet a line item
  # (legacy deals — the home price lives on selling_price and deals_controller#deal_json
  # injects a synthetic 'primary-vehicle' line). Detection spans BOTH home-line formats:
  # the Phase 3 FE's `category:home`-tagged CUSTOM-<uuid> line and a VEHICLE-<id> line
  # (see DealProduct#home_line_item?). When more than one home line exists (data anomaly),
  # prefer a VEHICLE-<id> line if present (it carries the vehicle id) else the first, and
  # log a warning so the anomaly is visible.
  def home_line_item
    homes = deal_products.select(&:home_line_item?)
    return homes.first if homes.size <= 1

    Rails.logger.warn(
      "[Deal] Deal #{id}: #{homes.size} home line items found " \
      "(ids #{homes.map(&:id).inspect}); using the VEHICLE-SKU line if present, else the first."
    )
    homes.detect(&:vehicle_line_item?) || homes.first
  end

  def has_home_line_item?
    home_line_item.present?
  end

  # PRE-TAX price of the HOME line item only: (unit_price * quantity) less the
  # line's discount. nil when there is no home line. This is THE home price —
  # selling_price mirrors it (Phase 2B). It is deliberately NOT line_items_price:
  # selling_price stays the home price (invoicing/GL/Deal Desk depend on that),
  # while line_items_price is the all-lines deal total (see below).
  def home_line_item_price
    hli = home_line_item
    hli ? line_item_price(hli) : nil
  end

  # PER-UNIT cost of the HOME line item (dp.cost × quantity). Mirrors
  # home_line_item_price on the cost side so backend front_gross reads the same
  # home cost the rep sees in the Deal Line Items card. Vehicle.structured_cost
  # is the fallback when no home line exists — but when the rep entered a
  # specific cost on the deal's home line (common: catalog cost differs from
  # the actual purchase order), that value wins. nil when no home line.
  def home_line_item_cost
    hli = home_line_item
    return nil unless hli
    qty = (hli.quantity || 1).to_i
    qty = 1 if qty < 1
    (hli.cost.to_f * qty).round(2)
  end

  # ALL-LINES TOTAL (the DEAL VALUE): pre-tax SUM of (unit_price*qty - discount)
  # across every deal_product — home + fees + accessories + recon. Discount math
  # mirrors DealProduct#line_profit / calculate_total.
  #
  # READ-ONLY helper for display (FE Grand Total) and reconciliation against the
  # `value` column / calculated_value. It is DISTINCT from selling_price (the home
  # price) and must NOT feed selling_price, invoicing, or GL — doing so would
  # double-count fees (selling_price is the home portion; fees are separate lines).
  def line_items_price
    deal_products.sum { |dp| line_item_price(dp) }.round(2)
  end

  # Sum of every line item's cost side: cost * quantity (DealProduct#line_cost_total).
  # READ-ONLY — not yet wired to landed_cost/COGS.
  def line_items_cost
    deal_products.sum { |dp| dp.line_cost_total }.round(2)
  end

  # ============================================================================
  # COMMISSION ECONOMICS CALCULATIONS
  # ============================================================================
  
  # ----------------------------------------------------------------------------
  # COST BASIS — single source of truth, sourced from the vehicle.
  #
  # OPEN deals read the vehicle's LIVE structured cost (read-through): editing the
  # home's cost recomputes GP everywhere with no deal re-save. CLOSED deals
  # (closed_won / gl_posted) use the cost SNAPSHOTTED onto the deal at close (home_cost),
  # so GP/COGS freeze and are auditable. 0/blank vehicle cost is treated as MISSING
  # (returns nil) — we never apply a default margin.
  # ----------------------------------------------------------------------------

  # True once the deal is closed/posted and its cost is frozen on the deal.
  def cost_snapshotted?
    gl_posted? || stage_is_won?
  end

  # The vehicle-cost portion of landed cost. Live from the vehicle while open; the
  # snapshot (home_cost) once closed. Falls back to unit_cost — the passive mirror of the
  # home LINE ITEM's cost, which is the number reps actually enter on the deal — and then
  # to the vehicle's live cost, so a closed deal is never stranded with nil cost just
  # because home_cost wasn't snapshotted (e.g. line items edited after close). nil only
  # when truly no cost exists anywhere.
  def vehicle_landed_cost
    if cost_snapshotted?
      hc = home_cost.to_f
      return hc.round(2) if hc > 0

      # home_cost not snapshotted (or zero) — fall back to unit_cost (mirrors the home
      # line item cost), then to the vehicle's structured cost. Keeps closed deals whose
      # cost lives on the line item from showing a missing/zero cost basis.
      uc = unit_cost.to_f
      return uc.round(2) if uc > 0

      live = vehicle&.structured_cost
      return live unless live.nil?

      return nil
    end

    # OPEN deal: prefer the HOME LINE ITEM's own cost — that's what the rep
    # entered on this specific deal and what the Deal Line Items UI displays
    # in the "Cost" column. Vehicle.structured_cost is the fallback for legacy
    # deals with no home line. This priority matches the FE's "Line Items
    # Profit" number and the Financial Details card's "Unit Cost (from home
    # line item)" label; the earlier vehicle-first order made backend
    # front_gross diverge whenever the rep priced a deal against a cost
    # different from the (possibly stale) vehicle.dealer_cost.
    hlc = home_line_item_cost
    return hlc if hlc && hlc > 0

    live = vehicle&.structured_cost
    return live unless live.nil?

    uc = unit_cost.to_f
    return uc.round(2) if uc > 0

    hc = home_cost.to_f
    hc > 0 ? hc.round(2) : nil
  end

  # HOME LANDED COST — the true acquisition cost of the unit that flows to COGS:
  # vehicle structured cost + reconditioning. Floor-plan interest and delivery are NOT
  # here — they're time/logistics CARRYING costs (see carrying_costs), kept out of front
  # gross so the margin view reconciles with the GL (which posts only home cost + recon
  # to COGS). nil (NOT zero) when the vehicle cost has not been entered, so GP can render
  # "—" and flag it.
  def landed_cost
    base = vehicle_landed_cost
    return nil if base.nil?

    (base + (reconditioning_cost || 0)).round(2)
  end

  # CARRYING / PERIOD COSTS — costs of owning + delivering the unit that vary with time
  # and logistics, not with how well the unit was sold: floor-plan interest (inventory
  # financing while it sat) + delivery/setup. These reduce NET profit, never front gross.
  # The GL treats them as period expenses (not COGS), so keeping them out of front gross
  # makes the margin view and the GL agree.
  def carrying_costs
    ((floor_plan_interest || 0) + (delivery_setup_cost || 0)).round(2)
  end

  # Whether a usable cost basis exists. When false, GP is "—" / "cost not entered".
  def cost_entered?
    !landed_cost.nil?
  end

  # FRONT-END ADD-ON MARGIN — the margin (price − cost) on every front-end add-on line
  # item: accessories, fees, services (allowance items like Trim Out / Delivery & Set /
  # Skirting / AC), land add-ons, and any "other" custom lines the rep adds. The home's
  # own margin is handled via selling_price − landed_cost; this captures the margin on
  # everything else the customer buys with the home. Back-end F&I products (category:
  # product) are excluded — they belong to back_gross. Uses each line's
  # (unit_price − cost) × quantity.
  #
  # Historical note: earlier this method only counted category:fee + category:accessory,
  # which silently dropped every allowance item (the FE hardcodes standard items to
  # category:service in DealLineItemsCard.tsx). Add-on margin therefore under-reported
  # on almost every MH deal until this widened.
  def front_end_addon_margin
    deal_products.sum do |dp|
      next 0.0 unless front_end_addon_line_item?(dp)
      qty = (dp.quantity || 1).to_f
      ((dp.unit_price.to_f - dp.cost.to_f) * qty)
    end.round(2)
  end

  # FRONT GROSS — the single canonical accounting gross. PRE-pack (pack is a dealer
  # holdback, not a cost — folding it in would break GP = revenue − COGS on the GL).
  # = (home margin) + (front-end add-on margins) − trade difference, where
  # home margin = selling_price − landed_cost (home cost + reconditioning).
  # Floor-plan interest and delivery are carrying costs and are EXCLUDED (they hit net).
  # Back-end F&I products are NOT part of front gross (they belong to back_gross).
  # nil when cost not entered.
  def front_gross
    lc = landed_cost
    return nil if lc.nil?

    trade_difference = (trade_payoff || 0) - (trade_allowance || 0)
    home_margin = (front_gross_home_price || 0) - lc - trade_difference
    (home_margin + front_end_addon_margin).round(2)
  end

  # Home PRICE used for front gross's home margin.
  #   - OPEN deal with a home line: the LIVE home line price (== selling_price,
  #     which the mirror keeps in sync). Reading the line keeps GP live as the rep
  #     edits the home line.
  #   - CLOSED/posted deal: the FROZEN selling_price. The mirror stopped at close,
  #     so this holds the close-time home price — editing the home line afterward
  #     does NOT move the closed deal's GP (matches the frozen cost snapshot).
  #   - Legacy deal with no home line: selling_price (the home price column).
  # Only the HOME line feeds this; fee/accessory lines are handled by
  # front_end_addon_margin, so the home is never double-counted.
  def front_gross_home_price
    return selling_price.to_f if cost_snapshotted? && selling_price.present?
    home_line_item_price || selling_price.to_f
  end

  # PACK (dealer holdback/administrative fee)
  def effective_pack_amount
    return pack_amount if pack_amount.present?
    return location.default_pack_amount if location&.default_pack_amount.present?
    company&.default_pack_amount || 0
  end

  # COMMISSIONABLE FRONT GROSS (what most dealers pay on) — accounting front gross
  # MINUS pack. Pack reduces commissionable gross (reps paid after the house takes its
  # holdback) but NOT accounting front gross. Preserve this distinction. nil when cost
  # not entered.
  def commissionable_front_gross
    fg = front_gross
    return nil if fg.nil?

    (fg - effective_pack_amount).round(2)
  end

  # BACK GROSS (finance & products)
  def back_gross
    ((finance_reserve || 0) + (product_margin || 0)).round(2)
  end

  # TOTAL GROSS — front_gross is nil when cost not entered; treat as 0 here so the
  # figure stays computable (the cost flag surfaces the missing-cost condition).
  def total_gross
    ((front_gross || 0) + back_gross).round(2)
  end
  
  # ============================================================================
  # FEES — source of truth migrated from deprecated columns to line items.
  #
  # Phase 3 moved fees off the deal columns (doc_fee/delivery_fee/setup_fee/
  # skirting_fee/accessories_total) and onto deal_products tagged in `notes` with
  # `category:fee` (DealForm.tsx) — and the FE now ZEROES those columns on every save.
  # These readers therefore must compute fee figures from the line items, not the
  # columns, or fees are silently understated in commissions, invoices, and contracts.
  #
  # Back-compat: when a deal has NO fee/accessory line items at all (legacy deals, or
  # records created via API that still populate the columns), fall back to the columns
  # so historical/integration data keeps reporting. A deal touched by the Phase 3 FE
  # has line items and zeroed columns, so the line items win — the point of this fix.
  # ----------------------------------------------------------------------------

  # Map a fee line item's name back to a canonical fee key, matching the Deal Desk +
  # FE naming convention (FEE_LINE_NAMES / category). nil for unrecognized names.
  FEE_NAME_TO_KEY = {
    'doc fee' => :doc, 'document fee' => :doc,
    'delivery fee' => :delivery, 'delivery / freight' => :delivery, 'freight' => :delivery,
    'setup fee' => :setup, 'setup charges' => :setup, 'set up fee' => :setup,
    'skirting fee' => :skirting, 'skirting' => :skirting
  }.freeze

  # Does this deal carry any fee/accessory line items? Determines whether to read
  # line items (Phase 3) or fall back to the deprecated columns (legacy/API deals).
  def has_fee_line_items?
    deal_products.any? { |dp| fee_line_item?(dp) || accessory_line_item?(dp) }
  end

  # Per-fee totals computed from line items. Keys: :doc :delivery :setup :skirting
  # :accessories :other. Uses each line's `total` (price*qty less discount), so qty>1
  # and discounted fee lines are reflected. An unrecognized fee name lands in :other so
  # it isn't silently dropped from add-on gross.
  def fee_totals_from_line_items
    totals = Hash.new(0.0)
    deal_products.each do |dp|
      if accessory_line_item?(dp)
        totals[:accessories] += dp.total.to_f
      elsif fee_line_item?(dp)
        normalized = normalize_fee_name(dp.product_name)
        key = FEE_NAME_TO_KEY[normalized]
        if key
          totals[key] += dp.total.to_f
        elsif normalized == 'accessories'
          totals[:accessories] += dp.total.to_f
        else
          totals[:other] += dp.total.to_f
        end
      end
    end
    totals
  end

  # Effective per-fee accessors: line items when present, else the legacy column.
  # Used by DealInvoiceService and the agreement merge fields so invoices/contracts
  # reflect the fees actually on the deal.
  def effective_doc_fee
    has_fee_line_items? ? fee_totals_from_line_items[:doc].round(2) : (doc_fee || 0).to_f
  end

  def effective_delivery_fee
    has_fee_line_items? ? fee_totals_from_line_items[:delivery].round(2) : (delivery_fee || 0).to_f
  end

  def effective_setup_fee
    has_fee_line_items? ? fee_totals_from_line_items[:setup].round(2) : (setup_fee || 0).to_f
  end

  def effective_skirting_fee
    has_fee_line_items? ? fee_totals_from_line_items[:skirting].round(2) : (skirting_fee || 0).to_f
  end

  def effective_accessories_total
    has_fee_line_items? ? fee_totals_from_line_items[:accessories].round(2) : (accessories_total || 0).to_f
  end

  # ADD-ON GROSS — total revenue (price × qty − discount) charged to the customer for
  # every front-end add-on line: fees, accessories, services (allowance items — Trim
  # Out, AC, Skirting, Delivery & Set), land, and custom "other" lines. Doc fee is
  # deliberately excluded (it's a pass-through, not commissionable add-on revenue).
  #
  # Sourced from `deal_products` when the deal has any add-on lines at all; falls back
  # to the deprecated columns (delivery_fee + setup_fee + skirting_fee + accessories_
  # total) only for legacy/API-created deals that predate Phase 3 line items.
  #
  # Note: this is REVENUE, not margin. Margin lives on front_end_addon_margin (which
  # feeds front_gross). Both were widened to include the same categories at the same
  # time, so revenue and margin now agree on what "add-on" means.
  def addon_gross
    if has_addon_line_items?
      deal_products.sum do |dp|
        next 0.0 unless front_end_addon_line_item?(dp)
        # Doc fee is excluded from add-on gross (commission-wise it's a pass-through).
        next 0.0 if fee_line_item?(dp) && normalize_fee_name(dp.product_name) == 'doc fee'
        line_item_price(dp)
      end.round(2)
    else
      ((delivery_fee || 0) + (setup_fee || 0) + (skirting_fee || 0) + (accessories_total || 0)).round(2)
    end
  end

  # True when the deal has ANY front-end add-on line (fee/accessory/service/land/other).
  # Widens has_fee_line_items? so addon_gross doesn't fall through to legacy columns on
  # a Phase 3 deal that only has service-category allowance items.
  def has_addon_line_items?
    deal_products.any? { |dp| front_end_addon_line_item?(dp) }
  end
  
  # Gross per unit (for multi-unit deals)
  def gross_per_unit
    units = (quantity || 1)
    units > 0 ? (total_gross / units).round(2) : 0
  end
  
  # Helper for checking if deal has trade
  def has_trade?
    trade_allowance.present? && trade_allowance > 0
  end
  
  # Validation: warn if trade has negative equity
  validate :trade_equity_check, if: :has_trade?
  
  def trade_equity_check
    if (trade_payoff || 0) > (trade_allowance || 0)
      negative_equity = ((trade_payoff || 0) - (trade_allowance || 0)).round(2)
      Rails.logger.warn("Deal #{id}: Negative equity of $#{negative_equity} (Payoff: $#{trade_payoff}, Allowance: $#{trade_allowance})")
    end
  end
  
  def delivered?
    stage_is_won? && delivery_date.present?
  end

  def just_closed_won?
    saved_change_to_stage? && stage_is_won?
  end

  def just_delivered?
    saved_change_to_stage? && stage_is_won? && delivery_date.present?
  end
  
  # Primary salesperson helper (deprecated - use association)
  def primary_salesperson
    User.find_by(id: primary_salesperson_id)
  end
  
  # Get all deal participants for commission calculation
  def all_participants
    participants = []
    participants << { user: primary_salesperson, role: 'primary_salesperson' } if primary_salesperson_id.present?
    participants << { user: sales_manager, role: 'sales_manager' } if sales_manager_id.present?
    participants << { user: finance_manager, role: 'finance_manager' } if finance_manager_id.present?
    participants << { user: desk_manager, role: 'desk_manager' } if desk_manager_id.present?
    participants << { user: secondary_salesperson, role: 'secondary_salesperson' } if secondary_salesperson_id.present?
    participants.compact
  end
  
  # Determine which commission plan applies to this deal (PUBLIC - called from controller)
  def determine_commission_plan
    return commission_plan if commission_plan_id.present?
    
    salesperson = primary_salesperson || owner
    return nil unless salesperson && company
    
    user_plan = company.commission_plans
      .active.current
      .where(assigned_user_id: salesperson.id)
      .first
    return user_plan if user_plan
    
    if salesperson.role.present?
      role_plan = company.commission_plans
        .active.current
        .where(assigned_role: salesperson.role)
        .first
      return role_plan if role_plan
    end
    
    company.commission_plans.active.current.defaults.first
  end

  # Generate commission payment records for this deal's participants. Called from the GL
  # approval flow (deal_approvals_controller#approve) — NOT at close — so commissions only
  # become payable after accounting approves the deal. Idempotent: the generator skips any
  # participant that already has a payment for this deal, so re-approval won't duplicate.
  def generate_commission_payments!
    return unless primary_salesperson_id.present?
    CommissionPaymentGeneratorService.generate_for_deal(self)
  rescue StandardError => e
    Rails.logger.error "[Deal] Failed to generate commission payment for deal #{id}: #{e.message}"
    nil
  end
  
  private
  
  # --- Fee line-item helpers (Phase 3 fee migration; see addon_gross above) -----
  # A fee line item: deal_product tagged `category:fee` in notes (FE/Deal Desk convention).
  def fee_line_item?(dp)
    dp.notes.to_s.match?(/category:\s*fee\b/i)
  end

  # An accessory line item: deal_product tagged `category:accessory` in notes. The old
  # accessories_total column maps to these (FE puts accessories under their own category).
  def accessory_line_item?(dp)
    dp.notes.to_s.match?(/category:\s*accessory\b/i)
  end

  # Any front-end add-on line: everything on the deal that is neither the home base
  # (`category:home`, handled separately by selling_price − landed_cost) nor a back-end
  # F&I product (`category:product`, folded into back_gross). Includes fee, accessory,
  # service (allowance items — Trim Out, AC, Skirting, etc.), land, and custom "other"
  # lines. Line items with no category tag at all are treated as front-end add-ons too:
  # a rep who typed a Custom Item is charging the customer something extra with a cost
  # basis, so it belongs in front-end margin.
  BACK_END_LINE_CATEGORIES = %w[home product].freeze

  def front_end_addon_line_item?(dp)
    category = extract_line_item_category(dp)
    return false if BACK_END_LINE_CATEGORIES.include?(category)
    true
  end

  def extract_line_item_category(dp)
    match = dp.notes.to_s.match(/category:\s*([a-z_]+)/i)
    match ? match[1].downcase : nil
  end

  def normalize_fee_name(str)
    str.to_s.strip.downcase.gsub(/\s+/, ' ')
  end

  # Pre-tax revenue of one line item: (unit_price * quantity) less the discount.
  # Discount math mirrors DealProduct#line_profit / calculate_total. Used by
  # home_line_item_price / line_items_price (Phase 2A/2B).
  def line_item_price(dp)
    subtotal = dp.quantity.to_i * dp.unit_price.to_f
    discount_amount = if dp.discount_type == 'percentage'
      subtotal * (dp.discount.to_f / 100.0)
    else
      dp.discount.to_f
    end
    (subtotal - discount_amount).round(2)
  end

  # before_save: mirror selling_price from the home line item (Phase 2B). See the
  # before_save :mirror_selling_price_from_home_line registration above for the full
  # rationale (home-price meaning, freeze-at-close, callback ordering).
  def mirror_selling_price_from_home_line
    return if closed_before_this_save?   # freeze once closed/posted
    return unless has_home_line_item?    # legacy/API deals: leave selling_price as-is
    self.selling_price = home_line_item_price
  end

  # True when the deal was ALREADY closed/posted before the current save — used to
  # freeze selling_price post-close. The closing save itself returns false (the
  # deal was open before it), so that save still mirrors the close-time home price.
  def closed_before_this_save?
    prior_stage = will_save_change_to_stage? ? stage_was : stage
    closed_keys = company ? company.closed_deal_stage_keys : %w[closed_won closed_lost]
    closed_keys.include?(prior_stage) || gl_posted?
  end

  # Auto-generate unique deal number per company (e.g. D-000001)
  def generate_deal_number
    return if deal_number.present?

    # Find the highest existing number for this company using safe SQL
    last_num = 0
    if company_id.present?
      result = self.class.connection.select_value(
        "SELECT MAX(CAST(SUBSTRING(deal_number FROM 3) AS INTEGER)) FROM deals " \
        "WHERE company_id = #{company_id} AND deal_number ~ '^D-[0-9]+$'"
      )
      last_num = result.to_i
    end

    self.deal_number = "D-#{(last_num + 1).to_s.rjust(6, '0')}"
  end

  # Auto-assign commission plan before save
  def auto_assign_commission_plan
    plan = determine_commission_plan
    self.commission_plan = plan if plan.present?
  end
  
  # Sync primary_salesperson_id with owner_id (for commission system)
  def sync_primary_salesperson
    self.primary_salesperson_id = owner_id
  end
  
  def sync_vehicle_sold_status
    previous_stage, _ = saved_change_to_stage
    DealVehicleStatusSync.call(self, previous_stage: previous_stage)
  rescue StandardError => e
    Rails.logger.error "[Deal] sync_vehicle_sold_status failed for deal #{id}: #{e.message}"
  end

  def notify_home_sold_other_deals
    NotifyHomeSoldOtherDealsService.call(self)
  rescue StandardError => e
    Rails.logger.error "[Deal] notify_home_sold_other_deals failed for deal #{id}: #{e.message}"
  end

  # Fire custom lifecycle webhook events on stage transitions
  def fire_lifecycle_webhooks
    event = if stage_is_won?  then 'deal.won'
            elsif stage_is_lost? then 'deal.lost'
            end
    return unless event

    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Deal] Failed to fire lifecycle webhook #{event}: #{e.message}"
  end

  # Sync vehicle pricing data when vehicle is assigned
  # Deal Desk on_close write-back (see the before_save above). Pulls the deal's single
  # selected scenario and writes its structure onto the deal via ASSIGNMENT ONLY
  # (assign_only: true) — folded into this in-flight save, so there's no nested deal.update
  # and no save re-entrancy. Never raises: a deal with no selected scenario simply closes.
  # Does NOT touch the close/GL/commission pipeline (commissions stay gated on GL-approval).
  def apply_selected_scenario_on_close
    scenario = deal_desk_scenarios.selected.first
    unless scenario
      Rails.logger.info("[DealDesk] Deal #{id} closing with no selected scenario; no write-back.")
      return
    end

    # Divergence guard: the deal was hand-edited after the scenario was selected. The
    # scenario is the source of truth at close, but make the silent overwrite visible.
    if selling_price.present? && scenario.unit_price_snapshot.present? &&
       selling_price.to_d != scenario.unit_price_snapshot.to_d
      Rails.logger.warn(
        "[DealDesk] Deal #{id} selling_price=#{selling_price} diverges from selected scenario " \
        "#{scenario.id} snapshot=#{scenario.unit_price_snapshot}; applying scenario (source of truth at close)."
      )
    end

    scenario.write_back_to_deal!(self, assign_only: true)
  end

  def sync_vehicle_pricing
    return unless vehicle_id.present?
    vehicle = Vehicle.find_by(id: vehicle_id)
    return unless vehicle
    
    vehicle_price = vehicle.sale_price || vehicle.msrp
    # Phase 2B: selling_price is mirrored from the home line item when one exists.
    # Only bootstrap it from the vehicle on the LEGACY path (no home line yet) so we
    # never clobber the mirror.
    self.selling_price = vehicle_price if (selling_price.nil? || selling_price == 0) && !has_home_line_item?
    # unit_cost is now a PASSIVE MIRROR of the canonical landed structured cost (see
    # vehicle_landed_cost/landed_cost), never an independent cost source. Mirror
    # structured_cost (not bare vehicle.cost) so it can never diverge from GP/COGS.
    self.unit_cost = vehicle.structured_cost if unit_cost.nil? || unit_cost == 0
    self.value = vehicle_price if value.nil? || value == 0
    self.quantity ||= 1

    # Auto-populate reconditioning + floor-plan interest ESTIMATES from the home so the
    # deal/approval starts pre-filled (accountant can override on approval). Only fill
    # when blank/zero so we never clobber a value already entered on the deal.
    if vehicle.respond_to?(:reconditioning_cost) && vehicle.reconditioning_cost.present? &&
       (reconditioning_cost.nil? || reconditioning_cost.zero?)
      self.reconditioning_cost = vehicle.reconditioning_cost
    end
    if vehicle.respond_to?(:floor_plan_interest_to_date) &&
       (floor_plan_interest.nil? || floor_plan_interest.zero?)
      fp_interest = vehicle.floor_plan_interest_to_date
      self.floor_plan_interest = fp_interest if fp_interest.to_f > 0
    end
    
    Rails.logger.info "[Deal] Synced pricing from vehicle #{vehicle_id}: selling_price=$#{selling_price}, unit_cost=$#{unit_cost}, value=$#{value}, recon=$#{reconditioning_cost}, fp_interest=$#{floor_plan_interest}"
  rescue StandardError => e
    Rails.logger.error "[Deal] Failed to sync vehicle pricing: #{e.message}"
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:title) || try(:name) || "Deal ##{id}"
  end

  def activity_module_name
    'crm'
  end

  def activity_account_id
    account_id
  end

  public

  after_commit :emit_workflow_created, on: :create
  after_commit :emit_workflow_updated, on: :update
  after_commit :emit_workflow_deleted, on: :destroy

  private

  def emit_workflow_created
    WorkflowEngine.emit('deal.created', self, { id: id })
  end

  def emit_workflow_updated
    changes = saved_changes.keys
    return if changes.blank?
    WorkflowEngine.emit('deal.updated', self, { id: id, changes: changes })
  end

  def emit_workflow_deleted
    WorkflowEngine.emit('deal.deleted', self, { id: id })
  end
end
