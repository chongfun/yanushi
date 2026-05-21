# app/services/payment_receipts/parsers/venmo.rb
module PaymentIngestions
  module Parsers
    class Venmo < Base
      def parse(pdf_text)
        raw_payer = extract_payer(pdf_text)
        raw_username = extract_username(pdf_text)
        IngestionResult.new(
          receipt_type: "venmo",
          payment_method: "venmo",
          raw_text: pdf_text,
          payer_name: clean_name(raw_payer),
          payer_username: clean_name(raw_username),
          amount: extract_amount(pdf_text),
          payment_date: extract_date(pdf_text),
          transaction_number: extract_transaction_id(pdf_text),
          success: true
        )
      rescue => e
        IngestionResult.new(
          receipt_type: "venmo",
          raw_text: pdf_text,
          error_message: e.message,
          success: false
        )
      end

      private

      def extract_payer(text)
        # Find display name line after "Transaction details" heading at top of page.
        # Format is typically:
        # Transaction details
        #
        #
        #
        #                    jane doe
        lines = text.split("\n").map(&:strip).reject(&:empty?)
        idx = lines.index("Transaction details")
        if idx && lines[idx + 1]
          lines[idx + 1]
        else
          # Fallback check
          nil
        end
      end

      def extract_username(text)
        match = text.match(/Received from\s+(@\S+)/i)
        match&.[](1)
      end

      def extract_amount(text)
        parse_amount(text)
      end

      def extract_date(text)
        # Look for e.g. "Mar 1, 2024, 6:41 PM" or "Mar 1, 2024"
        match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4},\s+\d{1,2}:\d{2}\s+(?:AM|PM))/i)
        return parse_date(match[1].strip) if match

        match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4})/i)
        return parse_date(match[1].strip) if match
        nil
      end

      def extract_transaction_id(text)
        match = text.match(/Transaction ID\s+(\d+)/i)
        match&.[](1)
      end
    end
  end
end
