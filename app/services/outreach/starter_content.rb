# frozen_string_literal: true

module Outreach
  # DealerTide's first playbook and product facts (Tom, 2026-11-18), written
  # from its help articles, website and campaign copy. It makes no claims about
  # competitors because none of those sources do. Other companies start empty,
  # so Renter Insight is never described as DealerTide.
  module StarterContent
    PRODUCT_FACTS = <<~TEXT.strip
      DealerTide is software for manufactured home retailers. CRM, quoting, inventory, deals, service, warranty, accounting and commissions live in one system, so nothing is entered twice.

      TrueBuild lets a buyer pick a floor plan, choose finishes and see a price on the dealer's website. A saved design becomes a lead with every option and price.

      DealerTide connects directly to Champion's inventory feed for specs, floor plans, photos and MSRP.

      Accounting is a real general ledger inside the system, or a two-way QuickBooks or Xero sync.

      Moving over: DealerTide migrates the dealer's data. On QuickBooks Online a dealer can run a trial switch first. It reads QuickBooks without changing anything there, and QuickBooks stays their books until they choose to go live.

      Customer service is based in the US. Pricing is never quoted in writing. It is covered on the demo.
    TEXT

    PLAYBOOK = [
      { 'objection' => 'How much does it cost?', 'action' => 'reply', 'share_hint' => '',
        'answer' => "It depends on how many locations you have and which parts of the system you would use, so I don't want to throw out a number that doesn't fit. On a 30 minute demo I can see what you need and go over real pricing. Would [two open times] work?" },
      { 'objection' => 'We already have a system', 'action' => 'reply', 'share_hint' => 'DealerTide in 80 seconds',
        'answer' => 'Most dealers I talk to do. What still lives in a spreadsheet or a second system? DealerTide keeps your CRM, inventory, deals, service, warranty, accounting and commissions together, so nothing gets entered twice. Worth 30 minutes to compare?' },
      { 'objection' => 'Not a good time', 'action' => 'reply', 'share_hint' => '',
        'answer' => 'Understood. When would be better for me to check back?' },
      { 'objection' => 'We are too small', 'action' => 'reply', 'share_hint' => '',
        'answer' => 'Smaller teams often feel double entry the most, since the same few people sell, order and handle service. DealerTide is built in modules, so we would only look at what fits your lot. What takes up the most of your week right now?' },
      { 'objection' => 'We use Trove', 'action' => 'reply', 'share_hint' => 'Let buyers design their home on your website',
        'answer' => 'Good to know. What do you like most about it, and what do you wish it did better? I can show you how DealerTide handles your website, TrueBuild, inventory, deals, installs and accounting in one system, and you can compare for yourself.' },
      { 'objection' => 'We use MH Manager', 'action' => 'reply', 'share_hint' => 'Let buyers design their home on your website',
        'answer' => 'Good to know. What works well for you, and where do you still end up working around it? I can show you how a buyer designs and prices a home on your website, then how that deal carries through inventory, installs and accounting.' },
      { 'objection' => 'We built our own', 'action' => 'reply', 'share_hint' => '',
        'answer' => 'That says a lot about how you like to run things. What does it do that you would never give up, and what do you wish it did? That would tell me quickly whether a demo is worth your time.' },
      { 'objection' => 'Switching sounds like too much work', 'action' => 'reply', 'share_hint' => '',
        'answer' => "That's the right thing to worry about. We migrate your data for you. If you are on QuickBooks Online, you can even run a trial switch first: it reads your QuickBooks without changing anything in it, and QuickBooks stays your books until you decide to go live." },
      { 'objection' => 'Just send me some information', 'action' => 'reply', 'share_hint' => 'The video that fits their answer',
        'answer' => "Happy to. What matters most right now: your website, inventory, installs or accounting? I'll send the short video that fits." },
      { 'objection' => 'Who are you, and how did you get my number?', 'action' => 'reply', 'share_hint' => '',
        'answer' => "This is Tom Schickel with DealerTide. Your information came from the [show name] list. We make software for manufactured home retailers. If you'd rather not hear from me, just say so and I'll take you off the list." },
      { 'objection' => 'Is this really Tom? Are you a bot?', 'action' => 'handoff', 'share_hint' => '',
        'answer' => "Fair question. I'm an AI assistant working with Tom Schickel. Tom runs every demo himself. Would you like him to reach out to you directly?" },
      { 'objection' => 'Stop, remove me, or not interested', 'action' => 'opt_out', 'share_hint' => '',
        'answer' => "Understood. I've taken you off the list and you won't hear from me again." }
    ].freeze

    module_function

    def available_for?(company)
      company.name.to_s.match?(/\ADealerTide\b/i)
    end
  end
end
