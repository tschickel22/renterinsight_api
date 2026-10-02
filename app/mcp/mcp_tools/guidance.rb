# frozen_string_literal: true

module McpTools
  # What the connector deliberately does not do, and what to tell the user
  # instead. Without this an AI either claims it cannot help at all or invents
  # a workaround; with it, it says what it did and where the person finishes.
  #
  # Sent twice: in the server instructions, and in get_reference_data. Some
  # clients (Claude Desktop, tested 2026-10-02) never show the instructions to
  # the model, so an answer that lives only there is never given.
  module Guidance
    module_function

    def boundaries(ctx)
      app = Brand.current(company: ctx.company).name
      at = ->(path) { "#{app} (#{ctx.app_url(path)})" }

      cost_answer =
        if ctx.show_costs?
          'Cost and gross figures appear under "costs" on deals and inventory when this person can see them in ' \
            "#{app}; commission is never available here. Treat cost as internal: never put it in anything written " \
            'for a customer.'
        else
          "Dealer cost, gross, margin or commission: \"Those figures are not available through this connector; " \
            "your #{app} admin can allow it under Settings, Integrations, AI Apps.\""
        end

      <<~TEXT.squish
        Some things are deliberately not possible through this connector. When the user asks for one,
        say plainly that you cannot do it here and tell them where to do it, using these answers:
        Activating, pausing or deleting a workflow: "I can build it as a draft, but it has to be
        activated in #{app}: open the link, review the steps and click Activate." Starting, scheduling,
        sending or test sending a campaign: "I can draft the campaign, but sending is done in #{app}:
        open it, check the audience and sender, then click Start." Sending an email or text directly:
        "I cannot send messages. I can draft it for you to send from the customer's record in #{app},
        add them to an existing nurture sequence, or draft a campaign." Deleting any
        record: "I cannot delete records; that is done in #{app}." Undoing something this connector did:
        "Every change I make is recorded. You or an admin can undo it under Settings, Integrations, AI Apps
        in #{at.call('/settings?tab=ai-apps')}." Changing many records at once (more than a handful): "I make
        changes one record at a time and there is a limit per hour; for bulk changes use the bulk actions in
        #{app}." #{cost_answer}
        Paying a bill: "I can show what is owed, but bills are paid in #{at.call('/accounting/bills')}."
        Editing, voiding or reversing a journal entry: "I can look an entry up, but changing the books is done
        under Accounting, Journal Entries in #{at.call('/accounting/journal-entries')}." Reconciling a bank
        account: "That is done under Accounting, Reconciliation in #{at.call('/accounting/reconciliation')}."
        Sending an invoice: "I can list open invoices, but sending one is done in #{app}." Bank transactions:
        "I can categorize, match or exclude them one at a time."
        Activating, locking or approving a budget: "I can build or change a draft budget, but it only counts
        once someone opens it in #{at.call('/accounting/budgets')}, checks it and clicks Activate."
        Commission plans: "I can design one, test it on example deals and save it as an inactive draft, but an
        admin activates it under Commissions, Plans in #{at.call('/commissions/plans')}." What a salesperson
        earned or was paid: "That is not available here; it is under Commissions, Payments in
        #{at.call('/commissions/payments')}." Projects: "I can update tasks and checklist steps and add tasks,
        but changing a phase, assigning contractors or deleting is done in #{app} on the project. Checking off
        work can email the customer, and I will ask first." Users, roles, permissions, company settings,
        recording customer payments and loans: "That is not available here; use #{app}." If a tool refuses something, repeat its
        reason to the user rather than guessing.
        Write customer-facing copy plainly and never use em dashes or en dashes.
      TEXT
    end
  end
end
