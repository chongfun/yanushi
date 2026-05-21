# app/services/payment_receipts/parsers/chase_statement.rb
module PaymentIngestions
  module Parsers
    class ChaseStatement < Base
      def parse(pdf_text)
        # Parse the statement period to determine the year context
        period_match = pdf_text.match(/([a-zA-Z]+\s+\d{1,2},\s+\d{4})\s+through\s+([a-zA-Z]+\s+\d{1,2},\s+\d{4})/i)

        if period_match
          start_date = parse_date(period_match[1])
          end_date = parse_date(period_match[2])
        else
          # Fallbacks if statement period is missing
          start_date = Date.current.beginning_of_year
          end_date = Date.current
        end

        results = []

        # Process line by line
        pdf_text.each_line do |line|
          line = line.strip
          next if line.empty?

          # 1. Zelle Match
          # Example: "03/24     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00"
          if (zelle_match = line.match(/^\s*(\d{2}\/\d{2})\s+Zelle Payment From\s+(.+?)\s+(\w+)\s+([\d,]+\.\d{2})\s+[\d,]+\.\d{2}\s*$/i))
            date_str, raw_payer, txn_number, amount_str = zelle_match[1], zelle_match[2], zelle_match[3], zelle_match[4]
            payment_date = resolve_date(date_str, start_date, end_date)
            amount = BigDecimal(amount_str.delete(","))

            results << IngestionResult.new(
              receipt_type: "chase_statement",
              payment_method: "zelle",
              raw_text: line,
              payer_name: clean_name(raw_payer),
              payer_username: nil,
              amount: amount,
              payment_date: payment_date,
              transaction_number: txn_number,
              success: true
            )

          # 2. P2P ACH Match
          # Example: "04/01     Oak Vly Com Bnk  P2P        John Doe     Web ID: 1770262278                   1,000.00        3,700.00"
          elsif (p2p_match = line.match(/^\s*(\d{2}\/\d{2})\s+(.+?\bP2P)\s+(.+?)\s+Web ID:\s*(\w+)\s+([\d,]+\.\d{2})\s+[\d,]+\.\d{2}\s*$/i))
            date_str, raw_payer, web_id, amount_str = p2p_match[1], p2p_match[3], p2p_match[4], p2p_match[5]
            payment_date = resolve_date(date_str, start_date, end_date)
            amount = BigDecimal(amount_str.delete(","))

            results << IngestionResult.new(
              receipt_type: "chase_statement",
              payment_method: "p2p",
              raw_text: line,
              payer_name: clean_name(raw_payer),
              payer_username: nil,
              amount: amount,
              payment_date: payment_date,
              transaction_number: web_id,
              success: true
            )
          end
        end

        results
      rescue => e
        [
          IngestionResult.new(
            receipt_type: "chase_statement",
            raw_text: pdf_text,
            error_message: e.message,
            success: false
          )
        ]
      end

      private

      def resolve_date(date_str, start_date, end_date)
        month, day = date_str.split("/").map(&:to_i)

        # Try with end_date's year first
        year = end_date.year
        d = Date.new(year, month, day)

        # If date is outside the statement period, try start_date's year
        if d < start_date || d > end_date
          year = start_date.year
          d = Date.new(year, month, day)
        end

        d
      rescue Date::Error
        Date.current
      end
    end
  end
end
