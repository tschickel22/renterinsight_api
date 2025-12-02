# frozen_string_literal: true

namespace :payments do
  desc "Backfill principal and interest amounts for existing payments"
  task backfill_breakdowns: :environment do
    puts "=" * 80
    puts "BACKFILLING PAYMENT PRINCIPAL/INTEREST BREAKDOWNS"
    puts "=" * 80
    puts ""

    # Find all loans with completed payments that have null/zero principal_amount
    loans_to_fix = Loan.joins(:payments)
                       .where(payments: { status: 'completed' })
                       .where('payments.principal_amount IS NULL OR payments.principal_amount = 0')
                       .distinct

    puts "Found #{loans_to_fix.count} loans with payments needing backfill"
    puts ""

    loans_to_fix.each do |loan|
      puts "-" * 80
      puts "Processing Loan ##{loan.id}"
      puts "  Original Principal: $#{loan.principal_amount}"
      puts "  Interest Rate: #{loan.interest_rate}%"
      puts "  Current Balance: $#{loan.current_balance}"
      puts ""

      # Get all completed payments in chronological order
      payments = loan.payments.where(status: 'completed').order(:payment_date)
      
      if payments.empty?
        puts "  No completed payments found. Skipping."
        next
      end

      # Start with the original principal
      remaining_balance = loan.principal_amount.to_f
      monthly_rate = loan.interest_rate.to_f / 100 / 12

      payments.each_with_index do |payment, index|
        payment_num = index + 1
        
        # Calculate interest on remaining balance
        interest_amount = remaining_balance * monthly_rate
        
        # Principal is payment amount minus interest and late fees
        late_fee = payment.late_fee_amount.to_f
        principal_amount = payment.amount.to_f - interest_amount - late_fee
        
        # Ensure principal doesn't go negative
        if principal_amount < 0
          puts "  ⚠️  Payment ##{payment_num}: Principal would be negative. Adjusting..."
          principal_amount = [payment.amount.to_f - late_fee, 0].max
          interest_amount = payment.amount.to_f - principal_amount - late_fee
        end

        # Update remaining balance
        remaining_balance -= principal_amount
        remaining_balance = 0 if remaining_balance < 0.01 # Handle rounding

        # Update the payment record
        payment.update!(
          principal_amount: principal_amount.round(2),
          interest_amount: interest_amount.round(2)
        )

        puts "  ✓ Payment ##{payment_num} (ID: #{payment.id}):"
        puts "    Date: #{payment.payment_date}"
        puts "    Amount: $#{payment.amount.round(2)}"
        puts "    Principal: $#{principal_amount.round(2)}"
        puts "    Interest: $#{interest_amount.round(2)}"
        puts "    Late Fee: $#{late_fee.round(2)}"
        puts "    New Balance: $#{remaining_balance.round(2)}"
      end

      puts ""
      puts "  Final calculated balance: $#{remaining_balance.round(2)}"
      puts "  Loan's current_balance: $#{loan.current_balance}"
      
      # Optionally update loan's current_balance if it doesn't match
      if (remaining_balance - loan.current_balance.to_f).abs > 0.01
        puts "  ⚠️  Balance mismatch detected!"
        puts "  Would you like to update loan.current_balance to $#{remaining_balance.round(2)}? (This is safe)"
      end
      
      puts ""
    end

    puts "=" * 80
    puts "BACKFILL COMPLETE"
    puts "=" * 80
  end

  desc "Backfill payment breakdowns for a specific loan"
  task :backfill_loan, [:loan_id] => :environment do |t, args|
    unless args[:loan_id]
      puts "Usage: bin/rails payments:backfill_loan[LOAN_ID]"
      exit 1
    end

    loan = Loan.find(args[:loan_id])
    
    puts "=" * 80
    puts "BACKFILLING LOAN ##{loan.id}"
    puts "=" * 80
    puts "  Original Principal: $#{loan.principal_amount}"
    puts "  Interest Rate: #{loan.interest_rate}%"
    puts "  Current Balance: $#{loan.current_balance}"
    puts ""

    payments = loan.payments.where(status: 'completed').order(:payment_date)
    
    if payments.empty?
      puts "No completed payments found."
      exit 0
    end

    remaining_balance = loan.principal_amount.to_f
    monthly_rate = loan.interest_rate.to_f / 100 / 12

    payments.each_with_index do |payment, index|
      payment_num = index + 1
      
      interest_amount = remaining_balance * monthly_rate
      late_fee = payment.late_fee_amount.to_f
      principal_amount = payment.amount.to_f - interest_amount - late_fee
      
      if principal_amount < 0
        principal_amount = [payment.amount.to_f - late_fee, 0].max
        interest_amount = payment.amount.to_f - principal_amount - late_fee
      end

      remaining_balance -= principal_amount
      remaining_balance = 0 if remaining_balance < 0.01

      payment.update!(
        principal_amount: principal_amount.round(2),
        interest_amount: interest_amount.round(2)
      )

      puts "Payment ##{payment_num} (ID: #{payment.id}):"
      puts "  Date: #{payment.payment_date}"
      puts "  Amount: $#{payment.amount.round(2)}"
      puts "  Principal: $#{principal_amount.round(2)}"
      puts "  Interest: $#{interest_amount.round(2)}"
      puts "  Late Fee: $#{late_fee.round(2)}"
      puts "  New Balance: $#{remaining_balance.round(2)}"
      puts ""
    end

    puts "Final Balance: $#{remaining_balance.round(2)}"
    
    # Update loan's current balance
    if (remaining_balance - loan.current_balance.to_f).abs > 0.01
      puts "Updating loan.current_balance from $#{loan.current_balance} to $#{remaining_balance.round(2)}"
      loan.update!(current_balance: remaining_balance.round(2))
    end
    
    puts "=" * 80
    puts "COMPLETE"
    puts "=" * 80
  end
end
